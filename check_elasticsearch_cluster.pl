#!/usr/bin/env perl
use strict;
use warnings;
use JSON;
use Nagios::Plugin;

my $np = Nagios::Plugin->new(shortname => "#");
my $code;

# root@syslog-test-search01:~# curl 'http://localhost:9200/_cluster/health?level=shards&pretty'
my %ES_STATUS = (
  "red" => 1,
  "yellow" => 2,
  "green" => 3,
);

my $json = <<'EOF';#{{{
{
  "cluster_name" : "logstash",
  "status" : "yellow",
  "timed_out" : false,
  "number_of_nodes" : 1,
  "number_of_data_nodes" : 1,
  "active_primary_shards" : 136,
  "active_shards" : 136,
  "relocating_shards" : 0,
  "initializing_shards" : 0,
  "unassigned_shards" : 136,
  "indices" : {
    "logstash-2015.03.23" : {
      "status" : "yellow",
      "number_of_shards" : 5,
      "number_of_replicas" : 1,
      "active_primary_shards" : 5,
      "active_shards" : 5,
      "relocating_shards" : 0,
      "initializing_shards" : 0,
      "unassigned_shards" : 5,
      "shards" : {
        "1" : {
          "status" : "yellow",
          "primary_active" : true,
          "active_shards" : 1,
          "relocating_shards" : 0,
          "initializing_shards" : 0,
          "unassigned_shards" : 1
        },
        "2" : {
          "status" : "yellow",
          "primary_active" : true,
          "active_shards" : 1,
          "relocating_shards" : 0,
          "initializing_shards" : 0,
          "unassigned_shards" : 1
        }
      }
    },
    "logstash-2015.02.18" : {
      "status" : "yellow",
      "number_of_shards" : 5,
      "number_of_replicas" : 1,
      "active_primary_shards" : 5,
      "active_shards" : 5,
      "relocating_shards" : 0,
      "initializing_shards" : 0,
      "unassigned_shards" : 5,
      "shards" : {
        "0" : {
          "status" : "yellow",
          "primary_active" : true,
          "active_shards" : 1,
          "relocating_shards" : 0,
          "initializing_shards" : 0,
          "unassigned_shards" : 1
        },
        "4" : {
          "status" : "yellow",
          "primary_active" : true,
          "active_shards" : 1,
          "relocating_shards" : 0,
          "initializing_shards" : 0,
          "unassigned_shards" : 1
        }
      }
    }
  }
}
EOF
#}}}

my $res;
# Try to parse the JSON
eval {
  $res = decode_json($json);
};
if ($@) {
  $np->nagios_exit(CRITICAL, "JSON was invalid: $@");
}

# Check so that queue isn't over the limit
$code = $np->check_threshold(
  check => $ES_STATUS{$res->{status}},
  # FIXME When we have more than one node, use this line instead:
  # warning => "\@$ES_STATUS{'yellow'}",
  warning => "\@$ES_STATUS{'red'}",
  critical => "\@$ES_STATUS{'red'}",
);
$np->add_message($code, "Cluster $res->{cluster_name} has status $res->{status}");


# "timed_out" : false,
if (defined $res->{timed_out} && !$res->{timed_out}) {
  $code = OK;
}
else {
  $code = CRITICAL;
}
$np->add_message($code, $res->{timed_out} ? "Connection to cluster timed out!" : "");

# "number_of_nodes" : 1,
# Set final status and message
($code, my $message) = $np->check_messages();
$np->nagios_exit($code, $message);
