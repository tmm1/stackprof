$:.unshift File.expand_path('../../lib', __FILE__)
require 'stackprof'
require 'stackprof/middleware'
require 'test/unit'
require 'mocha/setup'

class StackProf::MiddlewareTest < Test::Unit::TestCase

  def test_path_default
    StackProf::Middleware.new(Object.new)

    assert_equal 'tmp', StackProf::Middleware.path
  end

  def test_path_custom
    StackProf::Middleware.new(Object.new, { path: '/foo' })

    assert_equal '/foo', StackProf::Middleware.path
  end

  def test_save_default
    StackProf::Middleware.new(Object.new)

    StackProf.stubs(:results).returns({ mode: 'foo' })
    FileUtils.expects(:mkdir_p).with('tmp')
    File.expects(:open).with(regexp_matches(/^tmp\/stackprof-foo/), 'wb')

    StackProf::Middleware.save
  end

  def test_save_custom
    StackProf::Middleware.new(Object.new, { path: '/foo' })

    StackProf.stubs(:results).returns({ mode: 'foo' })
    FileUtils.expects(:mkdir_p).with('/foo')
    File.expects(:open).with(regexp_matches(/^\/foo\/stackprof-foo/), 'wb')

    StackProf::Middleware.save
  end

  def test_enabled_should_use_a_proc_if_passed
    env = {}

    StackProf::Middleware.new(Object.new, enabled: Proc.new{ false })
    refute StackProf::Middleware.enabled?(env)

    StackProf::Middleware.new(Object.new, enabled: Proc.new{ true })
    assert StackProf::Middleware.enabled?(env)
  end

  def test_enabled_should_use_a_proc_if_passed_and_use_the_request_env
    enable_proc = Proc.new {|env| env['PROFILE'] }

    env = Hash.new { false }
    StackProf::Middleware.new(Object.new, enabled: enable_proc)
    refute StackProf::Middleware.enabled?(env)

    env = Hash.new { true}
    StackProf::Middleware.new(Object.new, enabled: enable_proc)
    assert StackProf::Middleware.enabled?(env)
  end

  def test_mode_should_the_same_value_passed_when_no_proc
    env = {}
    expected_mode = :wall
    StackProf::Middleware.new(Object.new, mode: expected_mode)
    assert_equal expected_mode, StackProf::Middleware.mode(env)
  end

  def test_mode_should_be_the_return_value_of_the_proc_when_passed
    proc_called = false
    expected_mode = :foo
    env = Hash.new { expected_mode }

    mode_proc = Proc.new do |env|
      proc_called = true
      env['MODE']
    end

    StackProf::Middleware.new(Object.new, mode: mode_proc)
    assert_equal expected_mode, StackProf::Middleware.mode(env)
    assert proc_called
  end

  def test_mode_will_not_change_in_within_the_same_profile_capture
    app = Proc.new{ ['200', {'Content-Type' => 'omg/ponies'}, ['-']] }
    modes = [:wall, :cpu]
    mode_proc = Proc.new { modes.shift }
    middleware = StackProf::Middleware.new(app, enabled: true, mode: mode_proc, save_every: 3)

    StackProf.expects(:start).with(mode: :wall, interval: StackProf::Middleware.interval).times(3)
    3.times{ middleware.call({}) }
    StackProf.expects(:start).with(mode: :cpu, interval: StackProf::Middleware.interval).times(3)
    3.times{ middleware.call({}) }
  end

end
