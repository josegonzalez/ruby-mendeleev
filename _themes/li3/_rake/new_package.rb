require 'date'

desc "Begin a new package in _packages"
task :new_package do
  require_config

  unless ARGV.length > 1
    puts "USAGE: rake new_package 'github_username/li3_package'"
    exit(1)
  end

  data = { 'title' => ARGV[1] }

  slug = "#{ARGV[1].downcase.gsub(/[^\w\/]+/, '-')}"
  file = File.join(SOURCE_DIR, '_packages', "#{slug}.#{CONFIG['format']}")
  created = create_file(file, 'package', data)
  exit(created ? 0 : 1)
end

