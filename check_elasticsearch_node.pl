#!/usr/bin/env perl
# Copyright (c) 2013-, Simon Lundström <simlu@su.se>, IT Services, Stockholm University
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# Redistributions of source code must retain the above copyright notice, this
# list of conditions and the following disclaimer.
#
# Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
#
# Neither the name of Stockholm University nor the names of its contributors
# may be used to endorse or promote products derived from this software without
# specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
use strict;
use warnings;
use JSON;
use Nagios::Plugin;
use Data::Dumper;
use LWP::UserAgent;

# TODO FIXME
# *
#      "process" : {
#        "timestamp" : 1430813501430,
#        "open_file_descriptors" : 4167
#      },

# *
#      "jvm" : {
#        "timestamp" : 1430813501432,
#        "uptime_in_millis" : 84681165,
#        "mem" : {
#          "heap_used_in_bytes" : 17293203488,
#          "heap_used_percent" : 50,
#          "heap_committed_in_bytes" : 34290008064,
#          "heap_max_in_bytes" : 34290008064,
#          "non_heap_used_in_bytes" : 87888536,
#          "non_heap_committed_in_bytes" : 88911872,
#          "pools" : {
#            "young" : {
#              "used_in_bytes" : 39760320,
#              "max_in_bytes" : 558432256,
#              "peak_used_in_bytes" : 558432256,
#              "peak_max_in_bytes" : 558432256
#            },
#            "survivor" : {
#              "used_in_bytes" : 27668880,
#              "max_in_bytes" : 69730304,
#              "peak_used_in_bytes" : 69730304,
#              "peak_max_in_bytes" : 69730304
#            },
#            "old" : {
#              "used_in_bytes" : 17225774288,
#              "max_in_bytes" : 33661845504,
#              "peak_used_in_bytes" : 17573694632,
#              "peak_max_in_bytes" : 33661845504
#            }
#          }
#        },
#
#        The heap_used_percent metric is a useful number to keep an eye on. Elasticsearch is configured to initiate GCs when the heap reaches 75% full. If your node is consistently >= 75%, your node is experiencing memory pressure. This is a warning sign that slow GCs may be in your near future.
#
#        If the heap usage is consistently >=85%, you are in trouble. Heaps over 90–95% are in risk of horrible performance with long 10–30s GCs at best, and out-of-memory (OOM) exceptions at worst.
#        http://www.elastic.co/guide/en/elasticsearch/guide/current/_monitoring_individual_nodes.html

# *
#      "thread_pool" : {
#        "percolate" : {
#          "threads" : 0,
#          "queue" : 0,
#          "active" : 0,
#          "rejected" : 0,
#          "largest" : 0,
#          "completed" : 0
#        },
#        If the queue fills up to its limit, new work units will begin to be rejected, and you will see that reflected in the rejected statistic. This is often a sign that your cluster is starting to bottleneck on some resources, since a full queue means your node/cluster is processing at maximum speed but unable to keep up with the influx of work.

# *
#      "breakers" : {
#        "request" : {
#          "limit_size_in_bytes" : 13716003225,
#          "limit_size" : "12.7gb",
#          "estimated_size_in_bytes" : 0,
#          "estimated_size" : "0b",
#          "overhead" : 1.0,
#          "tripped" : 0
#        },
#        "fielddata" : {
#          "limit_size_in_bytes" : 20574004838,
#          "limit_size" : "19.1gb",
#          "estimated_size_in_bytes" : 1922942256,
#          "estimated_size" : "1.7gb",
#          "overhead" : 1.03,
#          "tripped" : 0
#        },
#        "parent" : {
#          "limit_size_in_bytes" : 24003005644,
#          "limit_size" : "22.3gb",
#          "estimated_size_in_bytes" : 1922942256,
#          "estimated_size" : "1.7gb",
#          "overhead" : 1.0,
#          "tripped" : 0
#        }
#      }
# The main thing to watch is the tripped metric. If this number is large or consistently increasing, it’s a sign that your queries may need to be optimized or that you may need to obtain more memory (either per box or by adding more nodes).

my $np = Nagios::Plugin->new(
  shortname => "#",
  usage => "Usage: %s [-v|--verbose] [-t <timeout>] [--critical=<value to emit critical>] [--warning=<value to emit warning>] --open-fds",
  timeout => 10,
  extra => qq(
See <https://nagios-plugins.org/doc/guidelines.html#THRESHOLDFORMAT> for
information on how to use thresholds.
The defaults has been been taken from
<http://www.elastic.co/guide/en/elasticsearch/guide/current/_monitoring_individual_nodes.html>
),
);

$np->add_arg(
  spec => 'open-fds',
  help => "--open-fds\n   Check how many file descriptors are open.",
);

$np->add_arg(
  spec => 'warning|w=s',
  help => [
    'Set the warning threshold in INTEGER (applies to breakers-tripped and thread-pool)',
    'Set the warning threshold in PERCENT (applies to open-fds, jvm-heap-used, breakers-size)',
  ],
  label => [ 'INTEGER', 'PERCENT%' ],
);

$np->add_arg(
  spec => 'critical|c=s',
  help => [
    'Set the critical threshold in INTEGER (applies to breakers-tripped and thread-pool)',
    'Set the critical threshold in PERCENT (applies to open-fds, jvm-heap-used, breakers-size)',
  ],
  label => [ 'INTEGER', 'PERCENT%' ],
);

$np->add_arg(
  spec => 'url=s',
  help => "--url\n   URL to your Elasticsearch instance. (default: %s)",
  default => 'http://localhost:9200',
);

$np->getopts;

sub get_json($) {
  my ($url) = @_;
  my $ua = LWP::UserAgent->new;
  # NRPE timeout is 10 seconds, give us 1 second to run
  $ua->timeout($np->opts->timeout-1);
  # Time out 1 second before LWP times out.
  $url = $np->opts->url.$url;
  my $response = $ua->get($url);

  if (!$response->is_success) {
    $np->nagios_exit(CRITICAL, $response->status_line);
  }
  my $json = $response->decoded_content;

  my $result;
  # Try to parse the JSON
  eval {
    $result = decode_json($json);
  };
  if ($@) {
    $np->nagios_exit(CRITICAL, "JSON was invalid: $@");
  }
  return $result;
}

my $code;
my $json = get_json("/_nodes/_local/stats?pretty");

# Check number of open file descriptors
if ($np->opts->get('open-fds')) {
  my $open_fds = $json->{nodes}->{(keys $json->{nodes})[0]}->{process}->{open_file_descriptors};
  # FIXME Check if it's an percentage and then get the maximum
  $code = $np->check_threshold(
    check => $open_fds,
    warning => $np->opts->warning,
    critical => $np->opts->critical,
  );
  $np->add_message($code, "Open file descriptors: $open_fds");
}
else {
  exec ($0, "--help");
}

($code, my $message) = $np->check_messages(join => ", ");
$np->nagios_exit($code, $message);
