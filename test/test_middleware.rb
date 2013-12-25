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

end
