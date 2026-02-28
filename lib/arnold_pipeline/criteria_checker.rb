module ArnoldPipeline
  class CriteriaChecker
    def self.call(criteria:, repo_path:)
      new(criteria, repo_path).call
    end

    def initialize(criteria, repo_path)
      @criteria = criteria
      @repo_path = repo_path
    end

    def call
      result = { verified: [], unverified: [], failed: [] }

      @criteria.each do |criterion|
        if criterion.runtime?
          result[:unverified] << criterion
        elsif criterion.static?
          check_static(criterion, result)
        else
          result[:unverified] << criterion
        end
      end

      result
    end

    private

    def check_static(criterion, result)
      passed = case criterion.type
      when "file_exists" then check_file_exists(criterion)
      when "test_exists" then check_test_exists(criterion)
      when "model_has" then check_model_has(criterion)
      when "route_exists" then check_route_exists(criterion)
      else false
      end

      if passed
        result[:verified] << criterion
      else
        result[:failed] << criterion
      end
    end

    def check_file_exists(criterion)
      pattern = criterion.params["pattern"]
      return false unless pattern

      matches = Dir.glob(File.join(@repo_path, pattern))
      matches.any?
    end

    def check_test_exists(criterion)
      pattern = criterion.params["pattern"]
      return false unless pattern

      matches = Dir.glob(File.join(@repo_path, pattern))
      return false if matches.empty?

      min_assertions = criterion.params["min_assertions"]&.to_i
      return true unless min_assertions && min_assertions > 0

      assertion_count = count_assertions(matches)
      assertion_count >= min_assertions
    end

    def check_model_has(criterion)
      model = criterion.params["model"]
      return false unless model

      columns = criterion.params["columns"] || []
      associations = criterion.params["associations"] || []

      return true if columns.empty? && associations.empty?

      schema_satisfied = check_schema(model, columns)
      assoc_satisfied = associations.empty? || check_associations(model, associations)

      schema_satisfied && assoc_satisfied
    end

    def check_route_exists(criterion)
      method = criterion.params["method"]&.downcase
      path = criterion.params["path"]
      return false unless method && path

      routes_content = read_routes_file
      return false unless routes_content

      route_pattern = build_route_pattern(method, path)
      routes_content.match?(route_pattern)
    end

    def count_assertions(files)
      count = 0
      files.each do |file|
        next unless File.file?(file)
        content = File.read(file)
        count += content.scan(/\b(assert|expect|should|it\s|test\s)/).size
      end
      count
    end

    def check_schema(model, columns)
      return true if columns.empty?

      schema_file = find_schema_file
      return false unless schema_file

      content = File.read(schema_file)
      table_name = model.underscore.pluralize

      table_block = extract_table_block(content, table_name)
      return false unless table_block

      columns.all? { |col| table_block.include?(col.to_s) }
    end

    def check_associations(model, associations)
      model_files = Dir.glob(File.join(@repo_path, "app/models/**/*.rb"))
      model_snake = model.underscore
      model_file = model_files.find { |f| File.basename(f, ".rb") == model_snake }
      return false unless model_file

      content = File.read(model_file)
      associations.all? { |assoc| content.match?(/\b#{Regexp.escape(assoc)}\b/) }
    end

    def find_schema_file
      candidates = [
        File.join(@repo_path, "db/schema.rb"),
        File.join(@repo_path, "db/structure.sql")
      ]
      candidates.find { |f| File.exist?(f) }
    end

    def extract_table_block(content, table_name)
      pattern = /create_table\s+"#{Regexp.escape(table_name)}".*?(?=create_table|\z)/m
      match = content.match(pattern)
      match&.[](0)
    end

    def read_routes_file
      routes_file = File.join(@repo_path, "config/routes.rb")
      return nil unless File.exist?(routes_file)
      File.read(routes_file)
    end

    def build_route_pattern(method, path)
      resource_name = path.split("/").reject(&:empty?).first
      return /(?:#{method}|resources?\s+:#{resource_name})/i if resource_name

      /#{method}/i
    end
  end
end
