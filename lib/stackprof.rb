require "stackprof/stackprof"

module StackProf
  VERSION = '0.2.13'
end

StackProf.autoload :Report, "stackprof/report.rb"
StackProf.autoload :Middleware, "stackprof/middleware.rb"
