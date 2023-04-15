# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'stackprof'
require 'minitest/autorun'

class StackProfTagsTest < MiniTest::Test
  def test_tag_fields_present_if_tags
    profile = StackProf.run(tags: [:thread_id]) do
      assert_operator StackProf::Tag.check, :==, {}
      math
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_equal true, profile.key?(:tag_strings)
  end

  def test_tag_fields_not_present_if_no_tags
    profile = StackProf.run do
      assert_operator StackProf::Tag.check, :==, {}
      math
    end

    assert_equal false, profile.key?(:sample_tags)
    assert_equal false, profile.key?(:tag_strings)
  end

  def test_one_tagset_per_profile
    profile = StackProf.run(tags: [:thread_id]) do
      assert_operator StackProf::Tag.check, :==, {}
      math
    end

    assert_equal profile[:samples], profile[:num_tags]
    assert_equal true, profile.key?(:sample_tags)
    assert_equal profile[:num_tags], profile[:sample_tags].select{|e| e.is_a?(Integer)}.inject(0, :+)
  end

private

  def math(n = 1)
    base = 250_000
    (n * base).times do
      2**10
    end
  end
end unless RUBY_ENGINE == 'truffleruby'
