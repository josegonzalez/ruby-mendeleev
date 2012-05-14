require 'filecache'
require 'git'

# For requests. Why is ruby so stupid about just making http requests
require 'open-uri'

PACKAGIST_CACHE = File.expand_path(File.join(File.dirname(__FILE__), '..', '..', '..', '..', '..', '_tmp'))

class Repository

  MODIFIER_REGEX = '[.-]?(?:(beta|RC|alpha|patch|pl|p)(?:[.-]?(\d+))?)?([.-]?dev)?'

  attr_accessor :cache, :packages

  def initialize(site)
    @cache = FileCache.new('packagist', PACKAGIST_CACHE, 86400, 3)
    @packages = {}

    repositories = self.fetch(site.source)
    self.process(repositories)
  end

  def fetch(source)
    files = []
    Dir.chdir(File.join(source, '_packages')) { files = filter_entries(Dir.glob('**/*.*')) }

    repositories = []
    files.each { |f| repositories << f.gsub(/.[\w]+$/, '') }
    repositories
  end

  def process(repositories)
    packages = []
    repositories.each do |repository|
      package = @cache.get("packages:#{repository}")
      unless package.nil?
        @packages[repository] = package
        next
      end

      count = 0
      package = {}

      refs(repository, 'tags').each do |tag, identifier|
        parsed = normalize(tag)
        next unless parsed

        data = composer_data(repository, identifier)
        next unless data

        if data.key?('version')
          data['version_normalized'] = normalize(data['version'])
        else
          data['version'] = tag
          data['version_normalized'] = parsed
        end

        data['version'] = data['version'].gsub(/[.-]?dev$/i, '')
        data['version_normalized'] = data['version'].gsub(/(^dev-|[.-]?dev$)/i, '')

        next if data['version_normalized'] != parsed

        count += 1
        package[data['version']] = pre_process(repository, identifier, data)
      end

      refs(repository, 'branches').each do |branch, identifier|
        parsed = normalize_branch(branch)
        next unless parsed

        data = composer_data(repository, identifier)
        next unless data

        data['version'] = branch;
        data['version_normalized'] = parsed;

        if parsed.match(/^dev-/) || '9999999-dev' == parsed
          data['version'] = 'dev-' + data['version']
        else
          data['version'] = parsed.gsub(/(\.9{7})+/, '.x')
        end

        count += 1
        package[data['version']] = pre_process(repository, identifier, data)
      end

      if count > 0
        @packages[repository] = package
        @cache.set("packages:#{repository}", package)
        next
      end

      @packages.delete(repository) if count == 0
    end
  end

  def refs(repository, type = 'tags')
    references = @cache.get("#{type}:#{repository}")
    return references unless references.nil?

    data = file_get_contents("https://api.github.com/repos/#{repository}/#{type}", { :type => 'json' })
    return {} unless data

    references = {}
    unless data.empty?
      data.each do |d|
        next if d['name'] == 'gh-pages'
        references[d["name"]] = d["commit"]["sha"]
      end
    end
    @cache.set("#{type}:#{repository}", references)
    references
  end

  def composer_data(repository, identifier)
    data = @cache.get("composer:#{repository}:#{identifier}")
    return data unless data.nil?

    data = file_get_contents("https://raw.github.com/#{repository}/#{identifier}/composer.json", { :type => 'json' })
    return false unless data

    unless data.fetch('time', false)
      commit = file_get_contents("https://api.github.com/repos/#{repository}/commits/#{identifier}", { :type => 'json' })
      return false unless commit

      data['time'] = commit['commit']['committer']['date'];
    end

    @cache.set("composer:#{repository}:#{identifier}", data)
    data
  end

  def pre_process(repository, identifier, data)
    unless data.fetch('dist', false)
      data['dist'] = get_dist(repository, identifier)
    end

    unless data.fetch('source', false)
      data['source'] = get_source(repository, identifier)
    end

    data['type'] = 'li3-libraries'
    data['homepage'] = "https://github.com/#{repository}" unless data.fetch('homepage', false)

    [ 'description', 'installation-source', 'release-date', 'target-dir' ].each do |k|
      data[k] = nil unless data.fetch(k, false)
    end

    # TODO: Handle Aliases
    # TODO: Handle Links
    # TODO: Handle Suggestions

    [ 'authors', 'autoload', 'bin', 'extra', 'keywords', 'license', 'scripts', ].each do |k|
      data[k] = [] unless data.fetch(k, false)
    end

    data
  end

  def get_dist(repository, identifier)
    label = identifier
    tags = refs(repository, 'tags')
    label = tags.key(identifier) if tags.value?(identifier)
    url = "https://github.com/#{repository}/zipball/#{label}"

    { :type => 'zip', :url => url, :reference => label, :shasum => ''}
  end

  def get_source(repository, identifier)
    label = identifier
    tags = refs(repository, 'tags')
    label = tags.key(identifier) if tags.value?(identifier)

    { :type => 'git', :url => "https://github.com/#{repository}", :reference => label}
  end


  def normalize(version)
    version = version.strip
    m, actual, version_alias = version.match(/^([^,\s]+) +as +([^,\s]+)$/).to_a
    version = version_alias unless version_alias.nil?

    return '9999999-dev' if version.match(/^(?:dev-)?(?:master|trunk|default)$/i)
    return version.downcase if version.match(/^dev\-/)

    regex_one = Regexp.new('^v?(\d{1,3})(\.\d+)?(\.\d+)?(\.\d+)?' + MODIFIER_REGEX + '$', true)
    regex_two = Regexp.new('^v?(\d{4}(?:[.:-]?\d{2}){1,6}(?:[.:-]?\d{1,3})?)' + MODIFIER_REGEX + '$', true)

    index = nil
    m = *version.match(regex_one)
    if m
      version = m[1] +
                (m[2].nil? || m[2].empty? ? '.0' : m[2]) +
                (m[3].nil? || m[3].empty? ? '.0' : m[3]) +
                (m[4].nil? || m[4].empty? ? '.0' : m[4])
      index = 5
    else
      m = version.match(regex_two)
      if m
        version = m[1].gsub(/\D/, '-')
        index = 2
      end
    end

    unless index.nil?
      unless m.to_a.fetch(index, nil).nil?
        append = m[index].downcase
        { 'patch' => /^pl?$/i, 'RC' => /^rc$/i }.each { |k, v| append = append.gsub(v, k) }
        version += '-' + append + (m.fetch(index + 1, nil) ? m.fetch(index + 1) : '' )
      end

      version += '-dev' unless m.fetch(index + 2, nil)
      return version
    end

    m = version.match(/(.*?)[.-]?dev$/i)
    if m
      branch = normalize_branch(m[1])
      return branch unless branc.nil?
    end

    false
  end

  def normalize_branch(name)
    name = name.strip

    return normalize(name) if ['master', 'trunk', 'default'].include?(name)

    m = name.match(/^v?(\d+)(\.(?:\d+|[x*]))?(\.(?:\d+|[x*]))?(\.(?:\d+|[x*]))?$/i)
    return 'dev-' + name unless m

    version = ''
    (1..4).each do |n|
      version += m.fetch(n, false) ? m.fetch(n).gsub('*', 'x') : '.x'
    end

    version.gsub('x', '9999999') + '-dev'
  end

  def file_get_contents(uri, opts = {})
    opts = { :type => nil, :cache => true }.merge(opts)
    begin
      data = open(uri).read
      data = Yajl::Parser.parse(data) if opts[:type] == 'json'
      @cache.set(uri, data) if opts[:cache]
      data
    rescue OpenURI::HTTPError => the_error
      @cache.set(uri, false) if opts[:cache]
      false
    end
  end

  def filter_entries(entries)
    entries = entries.reject do |e|
      unless ['.htaccess'].include?(e)
        ['.', '_', '#'].include?(e[0..0]) ||
        e[-1..-1] == '~' ||
        File.symlink?(e)
      end
    end
  end
end