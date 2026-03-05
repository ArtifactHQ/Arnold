require "test_helper"
require "arnold_pipeline/brownfield/parsers/java"

module ArnoldPipeline
  module Brownfield
    module Parsers
      class JavaTest < ActiveSupport::TestCase
        test "extracts class declaration" do
          result = Java.call(content: "public class UserService {\n}")
          assert_equal 1, result[:classes].length
          assert_equal "UserService", result[:classes][0][:name]
          assert_nil result[:classes][0][:superclass]
        end

        test "extracts class with extends" do
          result = Java.call(content: "public class Admin extends User {\n}")
          assert_equal [ { name: "Admin", superclass: "User", line: 1 } ], result[:classes]
        end

        test "extracts class with extends and implements" do
          result = Java.call(content: "public class UserService extends BaseService implements Serializable {\n}")
          assert_equal "UserService", result[:classes][0][:name]
          assert_equal "BaseService", result[:classes][0][:superclass]
        end

        test "extracts interface" do
          result = Java.call(content: "public interface UserRepository {\n}")
          assert_equal 1, result[:classes].length
          assert_equal "UserRepository", result[:classes][0][:name]
        end

        test "extracts interface with extends" do
          result = Java.call(content: "public interface UserRepo extends JpaRepository {\n}")
          assert_equal "UserRepo", result[:classes][0][:name]
          assert_equal "JpaRepository", result[:classes][0][:superclass]
        end

        test "extracts enum" do
          result = Java.call(content: "public enum Status {\n}")
          assert_equal 1, result[:classes].length
          assert_equal "Status", result[:classes][0][:name]
        end

        test "extracts abstract class" do
          result = Java.call(content: "public abstract class AbstractController extends BaseController {\n}")
          assert_equal "AbstractController", result[:classes][0][:name]
          assert_equal "BaseController", result[:classes][0][:superclass]
        end

        test "extracts class with generics" do
          result = Java.call(content: "public class Repository<T> extends BaseRepo<T> {\n}")
          assert_equal "Repository", result[:classes][0][:name]
          assert_equal "BaseRepo", result[:classes][0][:superclass]
        end

        test "extracts public methods" do
          code = <<~JAVA
            public class UserService {
                public List<User> findAll() {
                    return userRepo.findAll();
                }

                public User findById(Long id) {
                    return userRepo.findById(id);
                }
            }
          JAVA
          result = Java.call(content: code)
          assert_equal 2, result[:methods].length
          assert_equal "findAll", result[:methods][0][:name]
          assert_equal "public", result[:methods][0][:visibility]
          assert_equal "findById", result[:methods][1][:name]
        end

        test "extracts private methods" do
          result = Java.call(content: "    private void validateInput(String input) {\n    }")
          assert_equal 1, result[:methods].length
          assert_equal "validateInput", result[:methods][0][:name]
          assert_equal "private", result[:methods][0][:visibility]
        end

        test "extracts protected methods" do
          result = Java.call(content: "    protected String buildQuery() {\n    }")
          assert_equal 1, result[:methods].length
          assert_equal "buildQuery", result[:methods][0][:name]
          assert_equal "protected", result[:methods][0][:visibility]
        end

        test "extracts static methods" do
          result = Java.call(content: "    public static UserService getInstance() {\n    }")
          assert_equal 1, result[:methods].length
          assert_equal "getInstance", result[:methods][0][:name]
        end

        test "does not extract control flow as methods" do
          code = <<~JAVA
            public class Foo {
                public void bar() {
                    if (true) { }
                    for (int i = 0; i < 10; i++) { }
                    while (true) { }
                }
            }
          JAVA
          result = Java.call(content: code)
          method_names = result[:methods].map { |m| m[:name] }
          assert_includes method_names, "bar"
          refute_includes method_names, "if"
          refute_includes method_names, "for"
          refute_includes method_names, "while"
        end

        test "extracts annotations" do
          code = <<~JAVA
            @RestController
            @RequestMapping("/api")
            public class UserController {
                @GetMapping("/users")
                public List<User> getUsers() {
                    return service.findAll();
                }
            }
          JAVA
          result = Java.call(content: code)
          annotation_types = result[:callbacks].map { |c| c[:type] }
          assert_includes annotation_types, "RestController"
          assert_includes annotation_types, "RequestMapping"
          assert_includes annotation_types, "GetMapping"
        end

        test "annotations reference their target" do
          code = <<~JAVA
            @Override
            public String toString() {
                return name;
            }
          JAVA
          result = Java.call(content: code)
          assert_equal 1, result[:callbacks].length
          assert_equal "Override", result[:callbacks][0][:type]
          assert_equal "toString", result[:callbacks][0][:method]
        end

        test "extracts imports" do
          code = <<~JAVA
            import java.util.List;
            import java.util.ArrayList;
            import static org.junit.Assert.assertEquals;
            import org.springframework.web.bind.annotation.*;
          JAVA
          result = Java.call(content: code)
          assert_equal 4, result[:includes].length
          assert_includes result[:includes], "java.util.List"
          assert_includes result[:includes], "java.util.ArrayList"
          assert_includes result[:includes], "org.junit.Assert.assertEquals"
          assert_includes result[:includes], "org.springframework.web.bind.annotation.*"
        end

        test "extracts constants" do
          code = <<~JAVA
            public class Config {
                public static final int MAX_RETRIES = 3;
                private static final String API_URL = "https://api.example.com";
                static final long DEFAULT_TIMEOUT = 5000L;
            }
          JAVA
          result = Java.call(content: code)
          assert_equal 3, result[:constants].length
          assert_equal "MAX_RETRIES", result[:constants][0][:name]
          assert_equal "API_URL", result[:constants][1][:name]
          assert_equal "DEFAULT_TIMEOUT", result[:constants][2][:name]
        end

        test "returns all standard keys" do
          result = Java.call(content: "")
          expected_keys = %i[classes modules methods associations validations callbacks scopes includes constants]
          assert_equal expected_keys.sort, result.keys.sort
        end

        test "returns empty arrays for non-Java concepts" do
          result = Java.call(content: "public class Foo {}")
          assert_empty result[:modules]
          assert_empty result[:associations]
          assert_empty result[:validations]
          assert_empty result[:scopes]
        end

        test "realistic Spring Boot controller parsing" do
          code = <<~JAVA
            package com.example.app.controller;

            import org.springframework.web.bind.annotation.RestController;
            import org.springframework.web.bind.annotation.GetMapping;
            import org.springframework.web.bind.annotation.PostMapping;
            import org.springframework.beans.factory.annotation.Autowired;
            import java.util.List;

            @RestController
            @RequestMapping("/api/users")
            public class UserController extends BaseController {

                public static final String API_VERSION = "v1";

                @Autowired
                private UserService userService;

                @GetMapping
                public List<User> getAllUsers() {
                    return userService.findAll();
                }

                @PostMapping
                public User createUser(User user) {
                    return userService.save(user);
                }

                private void validateUser(User user) {
                    // validation logic
                }
            }
          JAVA
          result = Java.call(content: code)

          assert_equal 1, result[:classes].length
          assert_equal "UserController", result[:classes][0][:name]
          assert_equal "BaseController", result[:classes][0][:superclass]

          assert_equal 5, result[:includes].length
          assert result[:methods].any? { |m| m[:name] == "getAllUsers" }
          assert result[:methods].any? { |m| m[:name] == "createUser" }
          assert result[:methods].any? { |m| m[:name] == "validateUser" && m[:visibility] == "private" }
          assert_equal 1, result[:constants].length
          assert result[:callbacks].any? { |c| c[:type] == "RestController" }
          assert result[:callbacks].any? { |c| c[:type] == "GetMapping" }
        end
      end
    end
  end
end
