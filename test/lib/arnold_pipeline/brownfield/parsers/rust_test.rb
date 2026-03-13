require "test_helper"
require "arnold_pipeline/brownfield/parsers/rust"

module ArnoldPipeline
  module Brownfield
    module Parsers
      class RustTest < ActiveSupport::TestCase
        test "extracts struct" do
          result = Rust.call(content: "pub struct User {\n    name: String,\n}")
          assert_equal 1, result[:classes].length
          assert_equal "User", result[:classes][0][:name]
          assert_nil result[:classes][0][:superclass]
        end

        test "extracts private struct" do
          result = Rust.call(content: "struct Internal {\n}")
          assert_equal [ { name: "Internal", superclass: nil, line: 1 } ], result[:classes]
        end

        test "extracts enum" do
          code = <<~RUST
            pub enum Status {
                Active,
                Inactive,
                Pending,
            }
          RUST
          result = Rust.call(content: code)
          assert_equal 1, result[:classes].length
          assert_equal "Status", result[:classes][0][:name]
        end

        test "extracts both structs and enums" do
          code = <<~RUST
            pub struct Config {
                debug: bool,
            }

            pub enum LogLevel {
                Info,
                Warn,
                Error,
            }
          RUST
          result = Rust.call(content: code)
          assert_equal 2, result[:classes].length
          assert_equal "Config", result[:classes][0][:name]
          assert_equal "LogLevel", result[:classes][1][:name]
        end

        test "extracts modules" do
          code = <<~RUST
            pub mod handlers;
            mod utils;
          RUST
          result = Rust.call(content: code)
          assert_equal 2, result[:modules].length
          assert_equal "handlers", result[:modules][0][:name]
          assert_equal "utils", result[:modules][1][:name]
        end

        test "extracts public functions" do
          result = Rust.call(content: "pub fn process(input: &str) -> Result<String, Error> {\n}")
          assert_equal 1, result[:methods].length
          assert_equal "process", result[:methods][0][:name]
          assert_equal "public", result[:methods][0][:visibility]
        end

        test "extracts private functions" do
          result = Rust.call(content: "fn helper() -> bool {\n}")
          assert_equal 1, result[:methods].length
          assert_equal "helper", result[:methods][0][:name]
          assert_equal "private", result[:methods][0][:visibility]
        end

        test "extracts async functions" do
          result = Rust.call(content: "pub async fn fetch_data() -> Result<Data, Error> {\n}")
          assert_equal 1, result[:methods].length
          assert_equal "fetch_data", result[:methods][0][:name]
          assert_equal "public", result[:methods][0][:visibility]
        end

        test "extracts impl block methods" do
          code = <<~RUST
            impl User {
                pub fn new(name: String) -> Self {
                    Self { name }
                }

                fn validate(&self) -> bool {
                    !self.name.is_empty()
                }
            }
          RUST
          result = Rust.call(content: code)
          assert_equal 2, result[:methods].length
          assert_equal "new", result[:methods][0][:name]
          assert_equal "public", result[:methods][0][:visibility]
          assert_equal "validate", result[:methods][1][:name]
          assert_equal "private", result[:methods][1][:visibility]
        end

        test "extracts derive macros" do
          code = <<~RUST
            #[derive(Debug, Clone, Serialize)]
            pub struct Config {
                name: String,
            }
          RUST
          result = Rust.call(content: code)
          derives = result[:callbacks].select { |c| c[:type] == "derive" }
          assert_equal 3, derives.length
          assert_equal "Debug(Config)", derives[0][:method]
          assert_equal "Clone(Config)", derives[1][:method]
          assert_equal "Serialize(Config)", derives[2][:method]
        end

        test "extracts other attributes" do
          code = <<~RUST
            #[test]
            fn test_something() {
                assert!(true);
            }
          RUST
          result = Rust.call(content: code)
          attrs = result[:callbacks].select { |c| c[:type] == "test" }
          assert_equal 1, attrs.length
          assert_equal "test_something", attrs[0][:method]
        end

        test "extracts use statements" do
          code = <<~RUST
            use std::collections::HashMap;
            use serde::{Serialize, Deserialize};
            use crate::models::User;
          RUST
          result = Rust.call(content: code)
          assert_equal 3, result[:includes].length
          assert_includes result[:includes], "std::collections::HashMap"
          assert_includes result[:includes], "serde::{Serialize, Deserialize}"
          assert_includes result[:includes], "crate::models::User"
        end

        test "extracts constants" do
          code = <<~RUST
            pub const MAX_CONNECTIONS: usize = 100;
            const DEFAULT_PORT: u16 = 8080;
          RUST
          result = Rust.call(content: code)
          assert_equal 2, result[:constants].length
          assert_equal "MAX_CONNECTIONS", result[:constants][0][:name]
          assert_equal "DEFAULT_PORT", result[:constants][1][:name]
        end

        test "extracts static variables" do
          result = Rust.call(content: "static MAX_SIZE: usize = 1024;")
          assert_equal 1, result[:constants].length
          assert_equal "MAX_SIZE", result[:constants][0][:name]
        end

        test "extracts static mut" do
          result = Rust.call(content: "static mut GLOBAL_STATE: Option<State> = None;")
          assert_equal 1, result[:constants].length
          assert_equal "GLOBAL_STATE", result[:constants][0][:name]
        end

        test "returns all standard keys" do
          result = Rust.call(content: "")
          expected_keys = %i[classes modules methods associations validations callbacks scopes includes constants]
          assert_equal expected_keys.sort, result.keys.sort
        end

        test "returns empty arrays for non-Rust concepts" do
          result = Rust.call(content: "fn main() {}")
          assert_empty result[:associations]
          assert_empty result[:validations]
          assert_empty result[:scopes]
        end

        test "realistic Rust web service parsing" do
          code = <<~RUST
            use actix_web::{web, App, HttpServer, HttpResponse};
            use serde::{Serialize, Deserialize};
            use sqlx::PgPool;

            pub const API_VERSION: &str = "v1";
            const MAX_PAGE_SIZE: usize = 100;

            pub mod handlers;
            mod middleware;

            #[derive(Debug, Serialize, Deserialize)]
            pub struct User {
                id: i64,
                name: String,
                email: String,
            }

            #[derive(Debug, Serialize)]
            pub enum ApiError {
                NotFound,
                InternalError(String),
            }

            impl User {
                pub fn new(name: String, email: String) -> Self {
                    Self { id: 0, name, email }
                }

                pub async fn find_by_id(pool: &PgPool, id: i64) -> Result<Self, ApiError> {
                    todo!()
                }

                fn validate(&self) -> bool {
                    !self.name.is_empty() && self.email.contains('@')
                }
            }

            #[actix_web::main]
            async fn main() -> std::io::Result<()> {
                HttpServer::new(|| App::new())
                    .bind("127.0.0.1:8080")?
                    .run()
                    .await
            }
          RUST
          result = Rust.call(content: code)

          assert_equal 2, result[:classes].length # User struct, ApiError enum
          class_names = result[:classes].map { |c| c[:name] }
          assert_includes class_names, "User"
          assert_includes class_names, "ApiError"

          assert_equal 2, result[:modules].length
          assert_equal 4, result[:methods].length # new, find_by_id, validate, main

          assert_equal 3, result[:includes].length
          assert_equal 2, result[:constants].length

          # Derive macros for User and ApiError
          derives = result[:callbacks].select { |c| c[:type] == "derive" }
          assert derives.length >= 3 # Debug, Serialize, Deserialize for User
        end
      end
    end
  end
end
