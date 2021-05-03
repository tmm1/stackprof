require "stackprof/stackprof"

module StackProf
  VERSION = '0.2.17'
end

StackProf.autoload :Report, "stackprof/report.rb"
StackProf.autoload :Middleware, "stackprof/middleware.rb"
