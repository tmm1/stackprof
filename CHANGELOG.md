# 0.2.13

* Remove /ext from .gitignore
* update gemfile
* Add ruby 2.5 to CI targets
* comment some of the inner workings
* feature: add --json format
* Add test coverage around the string branch in result writing
* Flip conditional to use duck typing
* Allow Pathname objects for Stackprof :out
* Fix a compilation error and a compilation warning
* Add `--alphabetical-flamegraph` for population-based instead of timeline
* Add `--d3-flamegraph` to output html using d3-flame-graph
* Avoid JSON::NestingError when processing deep stacks
* Use docker for CI
