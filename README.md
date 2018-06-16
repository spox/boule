# boule

Local REST API for running terraform. It provides a specialized
interface for usage with the miasma-terraform provider implementation
of the miasma library.

## Installation

Download the latest release, or build it locally:

```
$ shards install
$ crystal build -o boule src/boule.cr
```

## Usage

Terraform must be available on the PATH. It can then be started:

```
$ ./boule
```

## Configuration options

Configuration is defined in JSON format.

* `logger.name` - name of the application
* `logger.path` - path to log file
* `logger.verbosity` - debug, info, warn, error, or fatal
* `terraform.directory` - storage directory for terraform assets
* `terraform.scrub_destroyed` - remove all file assets when destroyed

## Contributing

1. Fork it ( https://github.com/spox/boule/fork )
2. Create your feature branch (git checkout -b my-new-feature)
3. Commit your changes (git commit -am 'Add some feature')
4. Push to the branch (git push origin my-new-feature)
5. Create a new Pull Request

## Contributors

- [spox](https://github.com/chrisroberts) Chris Roberts - creator, maintainer
