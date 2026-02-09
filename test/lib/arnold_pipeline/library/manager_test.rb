require "test_helper"
require "arnold_pipeline/library/manager"

module ArnoldPipeline
  module Library
    class ManagerTest < ActiveSupport::TestCase
      setup do
        @manager = Manager.new
      end

      test "loads all personas" do
        personas = @manager.all_personas
        assert_equal 4, personas.size
        names = personas.map(&:name)
        assert_includes names, "Software Architect"
        assert_includes names, "Domain Expert"
        assert_includes names, "General Analyst"
        assert_includes names, "QA Analyst"
      end

      test "loads all recipes" do
        recipes = @manager.all_recipes
        assert_equal 4, recipes.size
        names = recipes.map(&:name)
        assert_includes names, "Web App"
        assert_includes names, "API Service"
        assert_includes names, "CLI Tool"
        assert_includes names, "Generic"
      end

      test "personas are Persona data objects" do
        persona = @manager.all_personas.first
        assert_kind_of Persona, persona
        assert_respond_to persona, :name
        assert_respond_to persona, :role
        assert_respond_to persona, :keywords
        assert_respond_to persona, :system_prompt
      end

      test "recipes are Recipe data objects" do
        recipe = @manager.all_recipes.first
        assert_kind_of Recipe, recipe
        assert_respond_to recipe, :name
        assert_respond_to recipe, :type
        assert_respond_to recipe, :keywords
        assert_respond_to recipe, :sections
      end

      test "find_persona matches software architect keywords" do
        persona = @manager.find_persona("Design a scalable microservices architecture")
        assert_equal "Software Architect", persona.name
      end

      test "find_persona matches domain expert keywords" do
        persona = @manager.find_persona("Build a fintech compliance workflow")
        assert_equal "Domain Expert", persona.name
      end

      test "find_persona matches qa analyst keywords" do
        persona = @manager.find_persona("Review testing coverage and validation")
        assert_equal "QA Analyst", persona.name
      end

      test "find_persona falls back to general analyst" do
        persona = @manager.find_persona("something completely unrelated xyzzy")
        assert_equal "General Analyst", persona.name
      end

      test "find_recipe matches web app keywords" do
        recipe = @manager.find_recipe("Build a responsive web dashboard")
        assert_equal "Web App", recipe.name
      end

      test "find_recipe matches api service keywords" do
        recipe = @manager.find_recipe("Create a REST API with JSON endpoints")
        assert_equal "API Service", recipe.name
      end

      test "find_recipe matches cli tool keywords" do
        recipe = @manager.find_recipe("Build a command line utility tool")
        assert_equal "CLI Tool", recipe.name
      end

      test "find_recipe falls back to generic" do
        recipe = @manager.find_recipe("something completely unrelated xyzzy")
        assert_equal "Generic", recipe.name
      end

      test "loads all domain types" do
        domain_types = @manager.all_domain_types
        assert_equal 13, domain_types.size
        codes = domain_types.map(&:code)
        %w[GAME SOCIAL PRODUCTIVITY MARKETPLACE CONTENT SERVICE ANALYTICS HEALTH EDUCATION FINTECH IOT CREATIVE GENERIC].each do |code|
          assert_includes codes, code
        end
      end

      test "domain types are DomainType data objects" do
        dt = @manager.all_domain_types.first
        assert_kind_of DomainType, dt
        assert_respond_to dt, :code
        assert_respond_to dt, :name
        assert_respond_to dt, :keywords
        assert_respond_to dt, :emphasis
        assert_respond_to dt, :document_focus
        assert_respond_to dt, :watch_for
        assert_respond_to dt, :terminology
      end

      test "find_domain_type matches game keywords" do
        dt = @manager.find_domain_type("build a multiplayer game with leaderboards")
        assert_equal "GAME", dt.code
      end

      test "find_domain_type matches health keywords" do
        dt = @manager.find_domain_type("build a fitness tracker for workouts")
        assert_equal "HEALTH", dt.code
      end

      test "find_domain_type matches fintech keywords" do
        dt = @manager.find_domain_type("create a budget and expense tracker for finance")
        assert_equal "FINTECH", dt.code
      end

      test "find_domain_type falls back to generic" do
        dt = @manager.find_domain_type("something completely unrelated xyzzy")
        assert_equal "GENERIC", dt.code
      end

      test "logs warning when falling back to generic persona" do
        logger = mock("logger")
        logger.expects(:warn).at_least_once
        manager = Manager.new(logger: logger)
        manager.find_persona("xyzzy completely unrelated nonsense")
      end

      test "logs warning when falling back to generic recipe" do
        logger = mock("logger")
        logger.expects(:warn).at_least_once
        manager = Manager.new(logger: logger)
        manager.find_recipe("xyzzy completely unrelated nonsense")
      end

      test "logs warning when falling back to generic domain type" do
        logger = mock("logger")
        logger.expects(:warn).at_least_once
        manager = Manager.new(logger: logger)
        manager.find_domain_type("xyzzy completely unrelated nonsense")
      end

      test "does not log when persona matches" do
        logger = mock("logger")
        logger.expects(:warn).never
        manager = Manager.new(logger: logger)
        manager.find_persona("Design a scalable microservices architecture")
      end

      test "supports custom library path" do
        custom_path = File.join(Dir.tmpdir, "arnold_test_library_#{Process.pid}")
        FileUtils.mkdir_p(File.join(custom_path, "personas"))
        FileUtils.mkdir_p(File.join(custom_path, "recipes"))

        File.write(File.join(custom_path, "personas", "custom.yml"), <<~YAML)
          name: Custom Persona
          role: custom
          keywords: [custom]
          description: A custom persona
          system_prompt: You are custom
        YAML

        File.write(File.join(custom_path, "recipes", "custom.yml"), <<~YAML)
          name: Custom Recipe
          type: custom
          keywords: [custom]
          description: A custom recipe
          sections: []
        YAML

        manager = Manager.new(library_path: custom_path)
        assert_equal 1, manager.all_personas.size
        assert_equal "Custom Persona", manager.all_personas.first.name
        assert_equal 1, manager.all_recipes.size
        assert_equal "Custom Recipe", manager.all_recipes.first.name
      ensure
        FileUtils.rm_rf(custom_path) if custom_path
      end
    end
  end
end
