# frozen_string_literal: true

require_relative 'custom_rule_loader'
require_relative 'rule_registry'
require_relative 'violation_filtering'
require_relative 'template_discovery'
require_relative 'result_view/simple_stdout_results'
require_relative 'result_view/json_results'
require 'cfn-model'

# Top-level CfnNag class for running profiles
class CfnNag
  include ViolationFiltering

  # rubocop:disable Metrics/ParameterLists
  def initialize(profile_definition: nil,
                 blacklist_definition: nil,
                 rule_directory: nil,
                 allow_suppression: true,
                 print_suppression: false,
                 isolate_custom_rule_exceptions: false)
    @rule_directory = rule_directory
    @custom_rule_loader = CustomRuleLoader.new(
      rule_directory: rule_directory,
      allow_suppression: allow_suppression,
      print_suppression: print_suppression,
      isolate_custom_rule_exceptions: isolate_custom_rule_exceptions
    )
    @profile_definition = profile_definition
    @blacklist_definition = blacklist_definition
  end
  # rubocop:enable Metrics/ParameterLists

  ##
  # Given a file or directory path, emit aggregate results to stdout
  #
  # Return an aggregate failure count (for exit code usage)
  #
  def audit_aggregate_across_files_and_render_results(input_path:,
                                                      output_format: 'txt',
                                                      parameter_values_path: nil,
                                                      template_pattern: '..*\.json|..*\.yaml|..*\.yml|..*\.template')
    aggregate_results = audit_aggregate_across_files input_path: input_path,
                                                     parameter_values_path: parameter_values_path,
                                                     template_pattern: template_pattern

    render_results(aggregate_results: aggregate_results,
                   output_format: output_format)

    aggregate_results.inject(0) do |total_failure_count, results|
      total_failure_count + results[:file_results][:failure_count]
    end
  end

  ##
  # Given a file or directory path, return aggregate results
  #
  def audit_aggregate_across_files(input_path:,
                                   parameter_values_path: nil,
                                   template_pattern: '..*\.json|..*\.yaml|..*\.yml|..*\.template')
    parameter_values_string = parameter_values_path.nil? ? nil : IO.read(parameter_values_path)
    templates = TemplateDiscovery.new.discover_templates(input_json_path: input_path,
                                                         template_pattern: template_pattern)
    aggregate_results = []
    templates.each do |template|
      aggregate_results << {
        filename: template,
        file_results: audit(cloudformation_string: IO.read(template),
                            parameter_values_string: parameter_values_string)
      }
    end
    aggregate_results
  end

  ##
  # Given cloudformation json/yml, run all the rules against it
  #
  # Optionally include JSON with Parameters key to substitute into
  # cfn_model.parameters
  #
  # Return a hash with failure count
  #
  def audit(cloudformation_string:, parameter_values_string: nil)
    violations = []

    begin
      cfn_model = CfnParser.new.parse cloudformation_string,
                                      parameter_values_string
      violations += @custom_rule_loader.execute_custom_rules(cfn_model)

      violations = filter_violations_by_blacklist_and_profile(violations)
    rescue Psych::SyntaxError, ParserError => parser_error
      violations << fatal_violation(parser_error.to_s)
    rescue JSON::ParserError => json_parameters_error
      error = "JSON Parameter values parse error: #{json_parameters_error}"
      violations << fatal_violation(error)
    end

    audit_result(violations)
  end

  private

  def filter_violations_by_blacklist_and_profile(violations)
    violations = filter_violations_by_profile(
      profile_definition: @profile_definition,
      rule_definitions: @custom_rule_loader.rule_definitions,
      violations: violations
    )

    # this must come after - blacklist should always win
    violations = filter_violations_by_blacklist(
      blacklist_definition: @blacklist_definition,
      rule_definitions: @custom_rule_loader.rule_definitions,
      violations: violations
    )
    violations
  rescue StandardError => blacklist_or_profile_parse_error
    violations << fatal_violation(blacklist_or_profile_parse_error.to_s)
    violations
  end

  def audit_result(violations)
    {
      failure_count: Violation.count_failures(violations),
      violations: violations
    }
  end

  def fatal_violation(message)
    Violation.new(id: 'FATAL',
                  type: Violation::FAILING_VIOLATION,
                  message: message)
  end

  def render_results(aggregate_results:,
                     output_format:)
    results_renderer(output_format).new.render(aggregate_results)
  end

  def results_renderer(output_format)
    registry = {
      'txt' => SimpleStdoutResults,
      'json' => JsonResults
    }
    registry[output_format]
  end
end
