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

def build_ruby_docker_image ruby_version = "ruby-head"
  image   = "stackprof-#{ruby_version}"
  sh_opts = []
  sh_opts = [{[:out, :err] => File::NULL}, {}] if @mute_build_output

  puts "\033[34m==>\033[0m \033[1mBuilding Docker Image for #{ruby_version}...\033[0m"
  sh "docker build -t #{image} --build-arg=RVM_RUBY_VERSION=#{ruby_version} .", *sh_opts
end

def run_tests_in_docker ruby_version = "ruby-head"
  sh "docker run --rm stackprof-#{ruby_version}"
end

namespace :test do
  namespace :docker do
    RUBY_VERSIONS = %w[2.1 2.2 2.3 2.4 2.5 2.6]

    RUBY_VERSIONS.each do |ruby_version|
      task "#{ruby_version}:build" do
        build_ruby_docker_image ruby_version
      end

      desc "Run tests in docker for Ruby #{ruby_version}"
      task ruby_version => "#{ruby_version}:build" do
        run_tests_in_docker ruby_version
      end
    end

    task "ruby-head:build" do
      build_ruby_docker_image
    end

    desc "Run tests in docker for ruby-head"
    task "ruby-head" => "ruby-head:build" do
      run_tests_in_docker
    end

    desc "Run tests in docker for all versions"
    task :all => %w[mute_build_output] + RUBY_VERSIONS + %w[ruby-head]

    desc "Clean created docker images"
    task :clean do
      images  = RUBY_VERSIONS.map {|rbv| "stackprof-#{rbv}" }
      images << "stackprof-ruby-head"
      sh "docker rmi --force #{images.join(' ')}", {[:out,:err] => File::NULL}
    end

    task :mute_build_output do
      @mute_build_output = true
    end
  end

  task :docker => "test:docker:all"
end
