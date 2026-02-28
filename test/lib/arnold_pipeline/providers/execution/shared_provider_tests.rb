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
          assert_includes [ true, false ], provider_instance.async?
        end

        def test_fetch_results_execution_metadata_shape
          # Providers may return execution_metadata as nil or Hash
          # This test verifies the contract is respected when results exist
          # Subclasses must set up @pipeline_run with at least one task that has stored results
          return unless respond_to?(:setup_fetch_results_for_metadata_test)

          setup_fetch_results_for_metadata_test
          results = provider_instance.fetch_results(pipeline_run: @pipeline_run)
          results.each do |r|
            meta = r[:execution_metadata]
            assert(meta.nil? || meta.is_a?(Hash),
              "execution_metadata must be nil or Hash, got #{meta.class}")
            assert_nothing_raised { meta&.to_json }
          end
        end
      end
    end
  end
end
