Gem::Specification.new do |s|
  s.name = 'stackprof'
  s.version = '0.1.0'
  s.homepage = 'http://github.com/tmm1/stackprof'

  s.authors = 'Aman Gupta'
  s.email   = 'aman@tmm1.net'

  s.files = `git ls-files`.split("\n")
  s.extensions = 'ext/extconf.rb'

  s.summary = 'sampling callstack-profiler for ruby 2.1+'
  s.description = 'stackprof is a fast sampling profiler for ruby code, with cpu, wallclock and object allocation samplers.'

  s.license = 'MIT'

  s.add_development_dependency 'rake-compiler'
end
