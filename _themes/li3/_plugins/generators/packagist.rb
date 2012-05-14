# Title: Packagist
# Description: Simulates packagist.org

require 'git'
require 'pathname'
require 'redcarpet'
require 'yajl'

require File.dirname(__FILE__) + '/../utilities/repository'

module Jekyll

  class Site
    attr_accessor :packages
  end

  class PackagistJson < Page
    def initialize(site, base, dir, data)
      @site = site
      @base = base
      @dir  = dir
      @name = 'packages.json'

      # Use the already cached layout content and data for theme support
      self.content = @site.layouts['packagist/json'].content
      self.data = @site.layouts['packagist/json'].data
      self.data['packages'] = Yajl::Encoder.encode(data)
      self.process(@name)
    end
  end

  class PackagistGenerator < Generator
    safe true
    priority :low

    def generate(site)
      return if !@enabled

      r = Repository.new(site)
      write_index(site, '/', r.packages)

      packages = []
      get_files(site, '_packages').each do |f|
        p = r.packages[f.gsub(/\.[\w]+$/, '')]
        package = PackagistPackage.new(site, site.source, '', f, p)
        if package.published
          packages << package
          package.render(site.layouts, site.site_payload)
          package.write(site.dest)
          site.static_files << package
        end
      end

      site.config['packages'] = packages
    end

    def write_index(site, dir, data)
      page = PackagistJson.new(site, site.source, dir, data)
      page.render(site.layouts, site.site_payload)
      page.write(site.dest)
      site.static_files << page
    end

    def get_files(site, folder)
      files = []
      Dir.chdir(File.join(site.source, folder)) { files = filter_entries(Dir.glob('**/*.*')) }
      files
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

  class PackagistPackage < Page
    include Convertible
    include Comparable

    MATCHER = /^(.+\/)*(.*)(\.[^.]+)$/

    attr_writer :dir
    attr_accessor :site
    attr_accessor :data, :content, :output, :ext, :json
    attr_accessor :date, :published, :tags, :categories, :maintainer, :package

    def initialize(site, source, dir, name, package)
      @site = site
      @base = File.join(source, dir, '_packages')
      @dir  = dir
      @name = name
      @cache = FileCache.new('packagist', PACKAGIST_CACHE, 86400, 3)

      # self.categories = cats.match(/^(.+\/)(?=[\w]+\/)/)[1].split('/').reject { |x| x.empty? }
      self.content = @site.layouts['packagist/package'].content
      self.data = @site.layouts['packagist/package'].data

      self.process(name)
      self.read_yaml(@base, name)
      self.parse_categories(name)
      self.data['readme'] = self.readme(name)
      self.date = Time.parse(self.data['date'].to_s) if self.data.key?('date')

      if self.data.key?('published') && self.data['published'] == false
        self.published = false
      else
        self.published = true
      end

      self.tags = self.data.pluralized_array("tag", "tags")
      package.each do |version, data|
        data['keywords'].each { |k| self.tags << k }
      end
      self.tags.uniq!

      if package.key?('dev-master') && package['dev-master'].key?('description')
        if !self.data.key?('description') || self.data['description'].nil? || self.data['description'].empty?
          self.data['description'] = package['dev-master']['description']
        end
      end

    end

    # Spaceship is based on Post#date, slug
    #
    # Returns -1, 0, 1
    def <=>(other)
      cmp = self.date <=> other.date
      if 0 == cmp
       cmp = self.package <=> other.package
      end
      return cmp
    end

    # Extract information from the post filename
    #   +name+ is the String filename of the post file
    #
    # Returns nothing
    def process(name)
      m, cats, package, ext = *name.match(MATCHER)
      m, maintainer = *cats.match(/([\w]+)\/$/)
      self.maintainer = maintainer
      self.package = package
      self.ext = ext
    rescue ArgumentError
      raise FatalException.new("Package #{name} does not have a valid date.")
    end

    # The full path and filename of the post.
    # Defined in the YAML of the post body
    # (Optional)
    #
    # Returns <String>
    def permalink
      self.data && self.data['permalink']
    end

    def template
      "/packages/:maintainer/:package/"
    end

    # The generated relative url of this post
    # e.g. /2008/11/05/my-awesome-post.html
    #
    # Returns <String>
    def url
      return @url if @url

      url = if permalink
        permalink
      else
        {
          "maintainer" => self.maintainer,
          "package"    => package,
          "title"      => CGI.escape(package),
          "categories" => categories.join('/'),
        }.inject(template) { |result, token|
          result.gsub(/:#{Regexp.escape token.first}/, token.last)
        }.gsub(/\/\//, "/")
      end

      # sanitize url
      @url = url.split('/').reject{ |part| part =~ /^\.+$/ }.join('/')
      @url += "/" if url =~ /\/$/
      @url
    end

    # The generated directory into which the page will be placed
    # upon generation. This is derived from the permalink or, if
    # permalink is absent, we be '/'
    #
    # Returns the String destination directory.
    def dir
      url[-1, 1] == '/' ? url : File.dirname(url)
    end


    # The UID for this post (useful in feeds)
    # e.g. /2008/11/05/my-awesome-post
    #
    # Returns <String>
    def id
      File.join(self.dir, self.package)
    end

    # Convert this post into a Hash for use in Liquid templates.
    #
    # Returns <Hash>
    def to_liquid
      self.data.deep_merge({
        "title"      => self.data["title"] || self.package.split('-').select {|w| w.capitalize! || w }.join(' '),
        "package"    => self.package,
        "maintainer" => self.maintainer,
        "url"        => self.url,
        "date"       => self.date,
        "id"         => self.id,
        "categories" => self.categories,
        "tags"       => self.tags,
        "content"    => self.content, })
    end

    def parse_categories(name)
      m, cats = *name.match(MATCHER)
      m, cats = cats.match(/^(.+\/)(?=[\w]+\/)/).to_a
      unless cats.nil?
        self.categories = cats[0].split('/').reject { |x| x.empty? }
      end

      if self.categories.nil? || self.categories.empty?
        self.categories = self.data.pluralized_array('category', 'categories')
      end
    end

    def readme(name)
      name = name.gsub(/\.[\w]+$/, '')
      readme = @cache.get("readme:#{name}")
      return readme unless readme.nil?

      repo = file_get_contents("https://api.github.com/repos/#{name}", { :type => 'json' })
      return false unless repo

      master_branch = repo.fetch('master_branch', 'master')
      return false unless master_branch

      tree = file_get_contents("https://api.github.com/repos/#{name}/git/trees/#{master_branch}", { :type => 'json' })
      return false unless tree

      path = false
      tree['tree'].each do |v|
        next if v['type'] != 'blob'

        if v['path'].match(/^(readme)(\.[\w]+)?$/i)
          path = v['path']
          break
        end
      end
      return false unless path

      readme = file_get_contents("https://raw.github.com/#{name}/master/#{path}")
      return false unless readme

      if path.match(/\.(markdown|mdown|mdwn|md|mkd|mkdn)?$/i)
        readme = Redcarpet.new(readme).to_html
      end

      @cache.set("readme:#{name}", readme)
      readme
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
  end
end