# nagios-plugin-elasticsearch

Nagios NRPE and "regular" checks for checking an Elasticsearch cluster and node status

## Dependencies

| CPAN module                           | Debian/Ubuntu package                               |
|---------------------------------------|-----------------------------------------------------|
| `JSON`                                | `libjson-perl`                                      |
| `Monitoring::Plugin`/`Nagios::Plugin` | `libmonitoring-plugin-perl`/`libnagios-plugin-perl` |
| `LWP::UserAgent`                      | `libwww-perl`                                       |

## Checks supported

For more details, see `--help` on respective check.

### Cluster
* Cluster status
* Index status
* Number of nodes online

### Node
* Open filedescriptors
* JVM heap usage
* Rejected work units in thread pools
* Breakers tripped
* Breakers memory size limit
