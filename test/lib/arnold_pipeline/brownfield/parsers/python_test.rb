require "test_helper"
require "arnold_pipeline/brownfield/parsers/python"

module ArnoldPipeline
  module Brownfield
    module Parsers
      class PythonTest < ActiveSupport::TestCase
        test "extracts class with base class" do
          result = Python.call(content: "class User(models.Model):\n    pass")
          assert_equal [{ name: "User", superclass: "models.Model", line: 1 }], result[:classes]
        end

        test "extracts class without base class" do
          result = Python.call(content: "class UserService:\n    pass")
          assert_equal [{ name: "UserService", superclass: nil, line: 1 }], result[:classes]
        end

        test "extracts class with empty parens" do
          result = Python.call(content: "class Config():\n    pass")
          assert_equal [{ name: "Config", superclass: nil, line: 1 }], result[:classes]
        end

        test "extracts class with multiple inheritance takes first" do
          result = Python.call(content: "class Admin(User, PermissionMixin):\n    pass")
          assert_equal "User", result[:classes][0][:superclass]
        end

        test "extracts multiple classes" do
          code = <<~PYTHON
            class Base:
                pass

            class Child(Base):
                pass
          PYTHON
          result = Python.call(content: code)
          assert_equal 2, result[:classes].length
          assert_equal "Base", result[:classes][0][:name]
          assert_equal "Child", result[:classes][1][:name]
        end

        test "extracts functions" do
          code = <<~PYTHON
            def hello():
                print("hello")

            def greet(name):
                print(f"hello {name}")
          PYTHON
          result = Python.call(content: code)
          assert_equal 2, result[:methods].length
          assert_equal "hello", result[:methods][0][:name]
          assert_equal "public", result[:methods][0][:visibility]
          assert_equal "greet", result[:methods][1][:name]
        end

        test "extracts methods inside classes" do
          code = <<~PYTHON
            class User:
                def __init__(self, name):
                    self.name = name

                def get_name(self):
                    return self.name

                def _internal(self):
                    pass

                def __secret(self):
                    pass
          PYTHON
          result = Python.call(content: code)
          assert_equal 4, result[:methods].length
          assert_equal "public", result[:methods][0][:visibility]   # __init__ (dunder)
          assert_equal "public", result[:methods][1][:visibility]   # get_name
          assert_equal "protected", result[:methods][2][:visibility] # _internal
          assert_equal "private", result[:methods][3][:visibility]   # __secret
        end

        test "extracts decorators" do
          code = <<~PYTHON
            @property
            def name(self):
                return self._name

            @staticmethod
            def create():
                pass

            @app.route('/users')
            def list_users():
                pass
          PYTHON
          result = Python.call(content: code)
          assert_equal 3, result[:callbacks].length
          assert_equal "property", result[:callbacks][0][:type]
          assert_equal "name", result[:callbacks][0][:method]
          assert_equal "staticmethod", result[:callbacks][1][:type]
          assert_equal "create", result[:callbacks][1][:method]
          assert_equal "app.route", result[:callbacks][2][:type]
          assert_equal "list_users", result[:callbacks][2][:method]
        end

        test "extracts stacked decorators" do
          code = <<~PYTHON
            @login_required
            @cache_page(60)
            def dashboard(request):
                pass
          PYTHON
          result = Python.call(content: code)
          assert_equal 2, result[:callbacks].length
          assert_equal "login_required", result[:callbacks][0][:type]
          assert_equal "dashboard", result[:callbacks][0][:method]
          assert_equal "cache_page", result[:callbacks][1][:type]
          assert_equal "dashboard", result[:callbacks][1][:method]
        end

        test "extracts import statements" do
          code = <<~PYTHON
            import os
            import sys
            from datetime import datetime
            from django.db import models
          PYTHON
          result = Python.call(content: code)
          assert_equal 4, result[:includes].length
          assert_includes result[:includes], "os"
          assert_includes result[:includes], "sys"
          assert_includes result[:includes], "datetime"
          assert_includes result[:includes], "django.db"
        end

        test "extracts constants" do
          code = <<~PYTHON
            MAX_RETRIES = 3
            API_URL = "https://api.example.com"
            DEBUG = True
          PYTHON
          result = Python.call(content: code)
          assert_equal 3, result[:constants].length
          assert_equal "MAX_RETRIES", result[:constants][0][:name]
          assert_equal "API_URL", result[:constants][1][:name]
          assert_equal "DEBUG", result[:constants][2][:name]
        end

        test "does not extract indented assignments as constants" do
          code = <<~PYTHON
            class Config:
                MAX_SIZE = 100
          PYTHON
          result = Python.call(content: code)
          # MAX_SIZE is indented, so it should not be extracted
          assert_empty result[:constants]
        end

        test "returns all standard keys" do
          result = Python.call(content: "")
          expected_keys = %i[classes modules methods associations validations callbacks scopes includes constants]
          assert_equal expected_keys.sort, result.keys.sort
        end

        test "returns empty arrays for non-Python concepts" do
          result = Python.call(content: "class Foo:\n    pass")
          assert_empty result[:modules]
          assert_empty result[:associations]
          assert_empty result[:validations]
          assert_empty result[:scopes]
        end

        test "realistic Django model parsing" do
          code = <<~PYTHON
            from django.db import models
            from django.contrib.auth.models import AbstractUser

            MAX_NAME_LENGTH = 255
            DEFAULT_ROLE = "member"

            class User(AbstractUser):
                email = models.EmailField(unique=True)
                role = models.CharField(max_length=50)

                class Meta:
                    ordering = ['-created_at']

                def __str__(self):
                    return self.email

                def get_full_name(self):
                    return f"{self.first_name} {self.last_name}"

                @property
                def is_admin(self):
                    return self.role == "admin"

            class Profile(models.Model):
                user = models.OneToOneField(User, on_delete=models.CASCADE)
                bio = models.TextField(blank=True)

                def __str__(self):
                    return f"Profile of {self.user}"
          PYTHON
          result = Python.call(content: code)

          assert_equal 3, result[:classes].length # User, Meta, Profile
          assert_equal "User", result[:classes][0][:name]
          assert_equal "AbstractUser", result[:classes][0][:superclass]
          assert_equal "Meta", result[:classes][1][:name]
          assert_equal "Profile", result[:classes][2][:name]
          assert_equal "models.Model", result[:classes][2][:superclass]

          assert result[:methods].length >= 4
          assert_equal 2, result[:includes].length
          assert_equal 2, result[:constants].length
          assert result[:callbacks].any? { |c| c[:type] == "property" }
        end

        test "realistic Flask app parsing" do
          code = <<~PYTHON
            from flask import Flask, jsonify, request
            from functools import wraps

            API_VERSION = "v1"

            def create_app():
                app = Flask(__name__)
                return app

            @app.route('/api/users', methods=['GET'])
            def list_users():
                return jsonify([])

            @app.route('/api/users', methods=['POST'])
            def create_user():
                data = request.get_json()
                return jsonify(data), 201
          PYTHON
          result = Python.call(content: code)

          assert result[:methods].any? { |m| m[:name] == "create_app" }
          assert result[:methods].any? { |m| m[:name] == "list_users" }
          assert result[:methods].any? { |m| m[:name] == "create_user" }
          assert_equal 1, result[:constants].length
          assert result[:callbacks].length >= 2
        end
      end
    end
  end
end
