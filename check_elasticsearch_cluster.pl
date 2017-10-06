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
sub load_module {
  for my $module (@_) {
    eval "use $module";
    return $module if !$@;
  }
  die $@;
}
my $monitoring_plugin;
BEGIN {
  $monitoring_plugin = load_module('Nagios::Plugin', 'Monitoring::Plugin');
}
use Data::Dumper;
use LWP::UserAgent;

my $np = $monitoring_plugin->new(
  shortname => "#",
  usage => "Usage: %s [-v|--verbose] [-t <timeout>] [--critical=<value to emit critical>] [--warning=<value to emit warning>] --one-of-the-checks-below",
  version => "1.3.1",
  timeout => 10,
  extra => qq(
See <https://nagios-plugins.org/doc/guidelines.html#THRESHOLDFORMAT> for
information on how to use thresholds.

The STATUS label can have three values:
* green - All primary and replica shards are allocated. Your cluster is 100%
operational.
* yellow - All primary shards are allocated, but at least one replica is
missing. No data is missing, so search results will still be complete. However,
your high availability is compromised to some degree. If more shards disappear,
you might lose data. Think of yellow as a warning that should prompt
investigation.
* red - At least one primary shard (and all of its replicas) are missing. This
means that you are missing data: searches will return partial results, and
indexing into that shard will return an exception.

The defaults has been been taken from
<https://www.elastic.co/guide/en/elasticsearch/guide/current/_cluster_health.html>
),
);

$np->add_arg(
  spec => 'cluster-status',
  help => "--cluster-status\n   Check the status of the cluster.",
);

$np->add_arg(
  spec => 'index-status',
  help => "--index-status\n   Check the status of the indexes.",
);

$np->add_arg(
  spec => 'nodes-online',
  help => "--nodes-online\n   Check the number of nodes online.",
);

$np->add_arg(
  spec => 'warning|w=s',
  help => [
    'Set the warning threshold in INTEGER (applies to nodes-online)',
    'Set the warning threshold in STATUS (applies to cluster-status and index-status)',
  ],
  label => [ 'INTEGER', 'STATUS' ],
);

$np->add_arg(
  spec => 'critical|c=s',
  help => [
    'Set the critical threshold in INTEGER (applies to nodes-online)',
    'Set the critical threshold in STATUS (applies to cluster-status and index-status)',
  ],
  label => [ 'INTEGER', 'STATUS' ],
);

$np->add_arg(
  spec => 'url=s',
  help => "--url\n   URL to your Elasticsearch instance. (default: %s)",
  default => 'http://localhost:9200',
);

$np->add_arg(spec => 'username|user|u=s',
    help => "Username for authentication",
    default => "",
);

$np->add_arg(spec => 'password|p=s',
    help => "Password for authentication",
    default => ""
);

$np->getopts;

my %ES_STATUS = (
  "red" => 1,
  "yellow" => 2,
  "green" => 3,
);
my ($warning, $critical) = ($np->opts->warning, $np->opts->critical);
my $code;
my $json;

# Turns an array into "first, second & last"
sub pretty_join {
  my ($a) = @_;
  return @{$a}[0] if $#{$a} == 0;
  return "" if $#{$a} == -1;
  return join(', ', @{$a}[0..$#{$a}-1]).
  ' & '.@{$a}[$#{$a}];
}

# Checks the status of "something"
sub check_status($$) {
  $code = $np->check_threshold(
    check => (ref $_[0] eq "HASH") ? $ES_STATUS{$_[0]->{status}} : $ES_STATUS{$_[0]},
    warning => "\@$ES_STATUS{$warning}",
    critical => "\@$ES_STATUS{$critical}",
  );
  $np->add_message($code, $_[1]);
}

sub get_threshold_value {
  my ($thresh, $value, $key) = @_;

  if (ref $thresh eq 'CODE') {
    return $thresh->($value, $key);
  }
  else {
    return $thresh;
  }
}

# Check a data structure with check_threshold.
# TODO Make sure it works recursively
sub check_each($$$$$) {
  my %statuses;
  my ($what, $where, $warning, $critical, $message) = @_;
  # Run check_threshold on everything
  foreach my $k (keys %$what) {
    my $current_key = $where->($what->{$k});

    my $warn = get_threshold_value($warning, $what->{$k}, $k);
    my $crit = get_threshold_value($critical, $what->{$k}, $k);

    my $code = $np->check_threshold(
      check => $current_key,
      warning => $warn,
      critical => $crit,
    );

    # and put in in a hash where the status is the key and the value an array
    # of the keys with that status
    push @{$statuses{$code}}, $k;
  }
  for my $code (keys %statuses) {
    # We don't care about OK checks, but add messages about everything else.
    if ($code ne 0 && $statuses{$code}) {
      $np->add_message($code, $message.pretty_join($statuses{$code}));
    }
  }
}

sub clean_extra_chars($) {
  my ($ret) = @_;
  $ret =~ s/[^\d\w]//g;
  return $ret;
}

sub to_threshold($$) {
  my ($ret, $original) = @_;
  $ret =~ s/[\d\w]+%?/$original/;
  return $ret;
}

my $ua = LWP::UserAgent->new;
# NRPE timeout is 10 seconds, give us 1 second to run
$ua->timeout($np->opts->timeout-1);
# Time out 1 second before LWP times out.
my $url = $np->opts->url."/_cluster/health?level=shards&timeout=".($np->opts->timeout-2)."s&pretty";

my $req = HTTP::Request->new(GET => $url);

# Username and Password are defined for basic auth
if ($np->opts->username and $np->opts->password) {
  $req->authorization_basic($np->opts->username, $np->opts->password);
}

my $resp = $ua->request($req);

if (!$resp->is_success) {
  $np->nagios_exit(CRITICAL, $resp->status_line);
}

$json = $resp->decoded_content;

# Try to parse the JSON
eval {
  $json = decode_json($json);
};
if ($@) {
  $np->nagios_exit(CRITICAL, "JSON was invalid: $@");
}

# Check that the cluster query didn't time out
if (defined $json->{timed_out} && $json->{timed_out}) {
  $np->nagios_exit(CRITICAL, "Connection to cluster timed out!");
}

# Check the status of the cluster.
if ($np->opts->get('cluster-status')) {
  # Set defaults
  $warning = $warning || "yellow";
  $critical = $critical || "red";

  check_status($json, "Cluster $json->{cluster_name} is $json->{status}");
}

# Check the status of the cluster.
elsif ($np->opts->get('index-status')) {
  # Set defaults
  $warning = $warning || '@yellow';
  $critical = $critical || '@red';

  check_each($json->{indices},
    sub {
      my ($f) = @_;
      return $ES_STATUS{$f->{status}};
    },
    to_threshold($warning, $ES_STATUS{clean_extra_chars($warning)}),
    to_threshold($critical, $ES_STATUS{clean_extra_chars($critical)}),
    "Indexes with issues: "
  );
}

# Check that we have the number of nodes we prefer online.
elsif ($np->opts->get('nodes-online')) {
  # Set defaults
  $warning = $warning || '3:';
  $critical = $critical || "2:";

  $code = $np->check_threshold(
    check => $json->{number_of_nodes},
    warning => $warning,
    critical => $critical,
  );
  $np->add_message($code, "Nodes online: $json->{number_of_nodes}");
}

else {
  exec ($0, "--help");
}

($code, my $message) = $np->check_messages();
$np->nagios_exit($code, $message);
