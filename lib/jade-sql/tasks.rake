require 'jade-sql/bin/generate_schema'

namespace :jade do
  desc "Generate schema.jd from db/structure.sql (INPUT, OUTPUT, TABLES, COLUMNS, MODULE)"
  task :schema do
    input       = ENV['INPUT']  || 'db/structure.sql'
    output      = ENV['OUTPUT'] || 'app/jade/schema.jd'
    tables      = ENV['TABLES']&.split(',')&.map(&:strip)&.reject(&:empty?)
    columns     = parse_columns_env(ENV['COLUMNS'])
    module_name = ENV['MODULE'] || 'Schema'

    JadeSql::SchemaGenerator
      .generate(File.read(input), tables:, columns:, module_name:)
      .map { |name, source| write_module(output, module_name, name, source) }
      .then { puts "wrote #{it.join(', ')}" }
  end

  def write_module(output, root_module, name, source)
    JadeSql::SchemaGenerator
      .module_path(root_module, name, output)
      .tap { FileUtils.mkdir_p(File.dirname(it)) }
      .tap { File.write(it, source) }
  end

  # COLUMNS="patients:id,age;visits:id,seen_on" — tables separated by `;`,
  # their columns by `,`. A table left out keeps all of its columns.
  def parse_columns_env(raw)
    return nil unless raw

    raw
      .split(';')
      .reject { it.strip.empty? }
      .to_h do
        table, cols = it.split(':', 2)
        raise "COLUMNS entry #{it.inspect} needs the form table:col,col" if cols.nil?

        [table.strip, cols.split(',').map(&:strip).reject(&:empty?)]
      end
  end
end
