module ArnoldPipeline
  module Providers
    module Execution
      module SharedProviderTests
        def test_responds_to_create_tasks
          assert_respond_to provider_instance, :create_tasks
        end

        def test_responds_to_fetch_results
          assert_respond_to provider_instance, :fetch_results
        end

        def test_responds_to_merge_results
          assert_respond_to provider_instance, :merge_results
        end

        def test_responds_to_async
          assert_respond_to provider_instance, :async?
        end

        def test_responds_to_recoverable_errors
          assert_respond_to provider_instance, :recoverable_errors
        end

        def test_recoverable_errors_returns_array
          assert_kind_of Array, provider_instance.recoverable_errors
        end

        def test_async_returns_boolean
          assert_includes [true, false], provider_instance.async?
        end
      end
    end
  end
end
