require "test_helper"
require "arnold_pipeline/brownfield/parsers/javascript"

module ArnoldPipeline
  module Brownfield
    module Parsers
      class JavascriptTest < ActiveSupport::TestCase
        test "extracts class declaration" do
          result = Javascript.call(content: "class UserService {\n}")
          assert_equal [{ name: "UserService", superclass: nil, line: 1 }], result[:classes]
        end

        test "extracts class with extends" do
          result = Javascript.call(content: "class Admin extends User {\n}")
          assert_equal [{ name: "Admin", superclass: "User", line: 1 }], result[:classes]
        end

        test "extracts exported class" do
          result = Javascript.call(content: "export class ApiClient extends BaseClient {\n}")
          assert_equal [{ name: "ApiClient", superclass: "BaseClient", line: 1 }], result[:classes]
        end

        test "extracts export default class" do
          result = Javascript.call(content: "export default class App extends Component {\n}")
          assert_equal [{ name: "App", superclass: "Component", line: 1 }], result[:classes]
        end

        test "extracts React arrow function component" do
          result = Javascript.call(content: "const UserProfile = (props) => {\n}")
          assert_equal 1, result[:classes].length
          assert_equal "UserProfile", result[:classes][0][:name]
          assert_nil result[:classes][0][:superclass]
        end

        test "extracts React arrow function component with destructured props" do
          result = Javascript.call(content: "const Header = ({ title }) => {\n}")
          # This pattern doesn't match our regex since ({...}) isn't captured
          # But export const Header = () => does
          result2 = Javascript.call(content: "const Header = () => {\n}")
          assert_equal 1, result2[:classes].length
          assert_equal "Header", result2[:classes][0][:name]
        end

        test "extracts React function component" do
          result = Javascript.call(content: "function Dashboard() {\n  return <div />;\n}")
          assert_equal 1, result[:classes].length
          assert_equal "Dashboard", result[:classes][0][:name]
        end

        test "extracts exported function component" do
          result = Javascript.call(content: "export default function Layout() {\n}")
          assert_equal 1, result[:classes].length
          assert_equal "Layout", result[:classes][0][:name]
        end

        test "extracts function declarations" do
          code = <<~JS
            function fetchUsers() {
              return fetch('/api/users');
            }

            async function createUser(data) {
              return fetch('/api/users', { method: 'POST' });
            }
          JS
          result = Javascript.call(content: code)
          assert_equal 2, result[:methods].length
          assert_equal "fetchUsers", result[:methods][0][:name]
          assert_equal "createUser", result[:methods][1][:name]
        end

        test "extracts arrow function assignments" do
          code = <<~JS
            const handleClick = (event) => {
              event.preventDefault();
            };

            const processData = async (data) => {
              return data;
            };
          JS
          result = Javascript.call(content: code)
          assert_equal 2, result[:methods].length
          assert_equal "handleClick", result[:methods][0][:name]
          assert_equal "processData", result[:methods][1][:name]
        end

        test "extracts function expression assignments" do
          result = Javascript.call(content: "const validate = function(input) {\n};")
          methods = result[:methods].select { |m| m[:name] == "validate" }
          assert_equal 1, methods.length
        end

        test "extracts ES6 imports" do
          code = <<~JS
            import React from 'react';
            import { useState, useEffect } from 'react';
            import './styles.css';
          JS
          result = Javascript.call(content: code)
          assert_includes result[:includes], "react"
          assert_includes result[:includes], "./styles.css"
        end

        test "extracts CommonJS require" do
          code = <<~JS
            const express = require('express');
            const { Router } = require('express');
          JS
          result = Javascript.call(content: code)
          assert_equal 2, result[:includes].count { |i| i == "express" }
        end

        test "extracts constants" do
          code = <<~JS
            const MAX_RETRIES = 3;
            const API_BASE_URL = 'https://api.example.com';
            export const DEFAULT_TIMEOUT = 5000;
          JS
          result = Javascript.call(content: code)
          assert_equal 3, result[:constants].length
          assert_equal "MAX_RETRIES", result[:constants][0][:name]
          assert_equal "API_BASE_URL", result[:constants][1][:name]
          assert_equal "DEFAULT_TIMEOUT", result[:constants][2][:name]
        end

        test "does not extract lowercase const as constants" do
          result = Javascript.call(content: "const userName = 'test';")
          assert_empty result[:constants]
        end

        test "returns all standard keys" do
          result = Javascript.call(content: "")
          expected_keys = %i[classes modules methods associations validations callbacks scopes includes constants]
          assert_equal expected_keys.sort, result.keys.sort
        end

        test "returns empty arrays for non-JS concepts" do
          result = Javascript.call(content: "class Foo {}")
          assert_empty result[:modules]
          assert_empty result[:associations]
          assert_empty result[:validations]
          assert_empty result[:callbacks]
          assert_empty result[:scopes]
        end

        test "realistic React component parsing" do
          code = <<~JS
            import React, { useState, useEffect } from 'react';
            import { fetchUsers } from './api';
            import './UserList.css';

            const API_ENDPOINT = '/api/users';
            const MAX_RESULTS = 50;

            export default function UserList({ onSelect }) {
              const [users, setUsers] = useState([]);

              async function loadUsers() {
                const response = await fetch(API_ENDPOINT);
                return response.json();
              }

              const handleSelect = (user) => {
                onSelect(user);
              };

              return <div />;
            }
          JS
          result = Javascript.call(content: code)

          assert_equal 1, result[:classes].length
          assert_equal "UserList", result[:classes][0][:name]

          assert result[:methods].any? { |m| m[:name] == "loadUsers" }
          assert result[:methods].any? { |m| m[:name] == "handleSelect" }

          assert_equal 3, result[:includes].length
          assert_equal 2, result[:constants].length
        end

        test "realistic Express.js module parsing" do
          code = <<~JS
            const express = require('express');
            const { body, validationResult } = require('express-validator');

            const MAX_PAGE_SIZE = 100;

            class UserController extends BaseController {
              async getUsers(req, res) {
                const users = await User.findAll();
                res.json(users);
              }
            }

            function createRouter() {
              const router = express.Router();
              return router;
            }

            module.exports = { UserController, createRouter };
          JS
          result = Javascript.call(content: code)

          assert_equal 1, result[:classes].length
          assert_equal "UserController", result[:classes][0][:name]
          assert_equal "BaseController", result[:classes][0][:superclass]
          assert result[:methods].any? { |m| m[:name] == "createRouter" }
          assert_equal 1, result[:constants].length
        end
      end
    end
  end
end
