$:.unshift File.expand_path('../lib', __FILE__)
require 'stackprof'

class A
  def initialize
    pow
    self.class.newobj
    math
  end

  def pow
    2 ** 100
  end

  def self.newobj
    Object.new
    Object.new
  end

  def math
    2.times do
      2 + 3 * 4 ^ 5 / 6
    end
  end
end

#profile = StackProf.run(mode: :object, interval: 1) do
#profile = StackProf.run(mode: :wall, interval: 1000) do
profile = StackProf.run(mode: :cpu, interval: 1000, raw: true, out: '/tmp/stackprof.dump') do
  1_000_000.times do
    A.new
  end
end
