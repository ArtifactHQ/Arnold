require "test_helper"
require "arnold_pipeline/ansi_color"

module ArnoldPipeline
  class AnsiColorTest < ActiveSupport::TestCase
    include AnsiColor

    test "bold wraps text with bold codes" do
      assert_equal "\e[1mhello\e[0m", bold("hello")
    end

    test "dim wraps text with dim codes" do
      assert_equal "\e[2mhello\e[0m", dim("hello")
    end

    test "red wraps text with red codes" do
      assert_equal "\e[31mhello\e[0m", red("hello")
    end

    test "green wraps text with green codes" do
      assert_equal "\e[32mhello\e[0m", green("hello")
    end

    test "yellow wraps text with yellow codes" do
      assert_equal "\e[33mhello\e[0m", yellow("hello")
    end

    test "cyan wraps text with cyan codes" do
      assert_equal "\e[36mhello\e[0m", cyan("hello")
    end

    test "magenta wraps text with magenta codes" do
      assert_equal "\e[35mhello\e[0m", magenta("hello")
    end

    test "bg_green wraps with green background and black text" do
      assert_equal "\e[42;30m PASS \e[0m", bg_green(" PASS ")
    end

    test "bg_red wraps with red background and white text" do
      assert_equal "\e[41;37m FAIL \e[0m", bg_red(" FAIL ")
    end

    test "composing bold and red nests codes" do
      result = bold(red("error"))
      assert_includes result, "\e[1m"
      assert_includes result, "\e[31m"
      assert_includes result, "error"
    end

    test "strip_ansi removes all ANSI escape codes" do
      styled = bold(red("hello"))
      assert_equal "hello", strip_ansi(styled)
    end
  end
end
