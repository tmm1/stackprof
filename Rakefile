require "bundler/gem_tasks"
require "rake/testtask"
require "ruby_memcheck"

test_config = lambda do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
end
Rake::TestTask.new(test: :compile, &test_config)
namespace :test do
  RubyMemcheck.config(binary_name: "stackprof/stackprof")
  RubyMemcheck::TestTask.new(valgrind: :compile, &test_config)
end if RUBY_PLATFORM =~ /linux/ && `which valgrind` && $?.success?

if RUBY_ENGINE == "truffleruby"
  task :compile do
    # noop
  end

  task :clean do
    # noop
  end
else
  require "rake/extensiontask"

  Rake::ExtensionTask.new("stackprof") do |ext|
    ext.ext_dir = "ext/stackprof"
    ext.lib_dir = "lib/stackprof"
  end
end

task default: %i(compile test)
