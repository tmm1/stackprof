task :default => :test

# ==========================================================
# Packaging
# ==========================================================

GEMSPEC = Gem::Specification::load('stackprof.gemspec')

require 'rubygems/package_task'
Gem::PackageTask.new(GEMSPEC) do |pkg|
end

# ==========================================================
# Ruby Extension
# ==========================================================

require 'rake/extensiontask'
Rake::ExtensionTask.new('stackprof', GEMSPEC) do |ext|
  ext.lib_dir = 'lib/stackprof'
end
task :build => :compile

# ==========================================================
# Testing
# ==========================================================

require 'rake/testtask'
Rake::TestTask.new 'test' do |t|
  t.test_files = FileList['test/test_*.rb']
end
task :test => :build
