require 'cocoapods-core'

# Parser for CocoaPods Podspec
# this parser is only used by the CocoaPodsCrawler
#
# http://docs.cocoapods.org/specification.html
#
class CocoapodsPodspecParser

  def logger
    if !defined?(@@log) || @@log.nil?
      @@log = Versioneye::DynLog.new("log/cocoapods.log", 10).log
    end
    @@log
  end

  # the same for all products
  attr_reader :language, :prod_type

  # the product source
  attr_reader :podspec

  # important parts of the parsed domain model output
  attr_reader :name, :prod_key, :version

  attr_accessor :base_url

  def initialize base_url = 'https://github.com/CocoaPods/Specs'
    @base_url  = base_url
    @language  = Product::A_LANGUAGE_OBJECTIVEC
    @prod_type = Project::A_TYPE_COCOAPODS
  end


  # Public: parses a podspec file
  #
  # file  - the Podspec file path
  #
  # Returns a Product
  def parse_file ( file )
    @podspec = load_spec file
    return nil unless @podspec

    set_prod_key_and_version

    @product = find_or_create_product
    update_product

    @product
  end


  def load_spec file
    Pod::Spec.from_file(file)
  rescue => e
    logger.error e.message
    logger.error e.backtrace.join("\n")
    nil
  end

  def set_prod_key_and_version
    @name     = @podspec.name
    @prod_key = @podspec.name.downcase
    @version  = @podspec.version.to_s
  end


  def find_or_create_product
    product = Product.find_by_lang_key(Product::A_LANGUAGE_OBJECTIVEC, prod_key)
    return product if !product.nil?

    product = Product.new
    product.update_attributes({
      :reindex       => true,
      :prod_key      => prod_key,
      :name          => name,
      :name_downcase => prod_key,
      :description   => description,

      :language      => language,
      :prod_type     => prod_type,
    })
    product.save
    logger.info "New product created: #{product.to_s}"
    product
  end


  def update_product
    create_version
    create_license
    create_dependencies
    create_repository
    create_developers
    create_homepage_link
    create_github_podspec_versionarchive
    create_screenshot_links
    @product.save
    @product
  rescue => e
    logger.error e.message
    logger.error e.backtrace.join("\n")
    nil
  end


  def create_dependencies
    deps = get_podspec_dependencies
    hash = hash_of_dependencies_to_versions(deps)
    hash.each_pair do |spec, version|
      create_dependency(spec, version)
    end
  end

  # returns a list of dependencies
  def get_podspec_dependencies
    subspecs = @podspec.subspecs || []

    # get all dependencies of all sub dependencies
    sub_deps = subspecs.map(&:dependencies).flatten

    # remove subspecs from dependencies
    # (for when a subspec depends on other parts of the spec)
    subspec_start = "#{@podspec.name}/"
    sub_deps.delete_if {|d| d.name.start_with? subspec_start}

    podspec.dependencies.concat(sub_deps)
  end

  # creates a hash where every key is a dependency and the value is the version
  def hash_of_dependencies_to_versions deps
    hash_array = deps.map do |dep|
      hash = {name: dep.name, version: dep.requirement.as_list}
      hash[:spec], hash[:subspec] = CocoapodsPackageManager.spec_subspec( dep.name )
      hash
    end

    specs = ( hash_array.map { |hash| hash[:spec] } ).uniq
    hash_array.inject({}) do |result,hash|
      spec = hash[:spec]
      if specs.member? spec
        result[spec] = hash[:version]
        specs.delete spec
      end
      result
    end
  end


  def create_dependency dep_name, dep_version
    # make sure it's really downcased
    dep_prod_key = dep_name.downcase
    dependency_version = dep_version.is_a?(Array) ? dep_version.first : dep_version.to_s

    dependency = Dependency.find_by(language, prod_key, version, dep_name, dependency_version, dep_prod_key)
    return dependency if dependency

    dependency = Dependency.new({
      :language     => language,
      :prod_type    => prod_type,
      :prod_key     => prod_key,
      :prod_version => version,

      :name         => dep_name,
      :dep_prod_key => dep_prod_key,
      :version      => dependency_version,
      })
    dependency.save
    dependency
  end


  def create_version
    # versions aren't stored at product
    # this is what ProductService.update_version_data does
    version_numbers = @product.versions.map(&:version)
    return nil if version_numbers.member? version

    @product.add_version( version )
    logger.info " - new version #{version} for #{@product.language}/#{@product.prod_key}"

    CrawlerUtils.create_newest @product, version
    CrawlerUtils.create_notifications @product, version
  end


  def create_license
    type = @podspec.license[:type]
    return nil if type.nil?

    match = @podspec.license[:type].match(/type\s*=>\s*['"](\w+)['"]/i) # Special Case for PubNub
    if match
      type = match[1]
    end
    text = @podspec.license[:text]
    match = @podspec.license[:type].match(/text\s*=>\s*<<-LICENSE['"][\\n]*([\w\s\W]*)/i) # Special Case for PubNub
    if match
      text = match[1]
    end
    License.find_or_create language, prod_key, version, type, nil, text
  rescue => e
    logger.error e.message
    logger.error e.backtrace.join("\n")
    nil
  end


  def create_repository
    repo = repository
    if @product.repositories.nil?
      @product.repositories = []
    end
    if @product.repositories.empty?
      @product.repositories.push( repo )
      return nil
    end
    @product.repositories.each do |repo|
      return nil if repo.src.eql?(@base_url)
    end
    @product.repositories.push( repo )
  end

  def repository
    Repository.new({
      :repotype => Project::A_TYPE_COCOAPODS,
      :src => @base_url
      })
  end

  def create_developers
    @podspec.authors.each_pair do |name, email|
      developer = Developer.find_by( language, prod_key, version, name ).first
      next if developer

      developer = Developer.new({
        :language => language,
        :prod_key => prod_key,
        :version  => version,

        :name     => name,
        :email    => email
        })
      developer.save
    end
  end

  def create_homepage_link
    # checking for valid link is done inside create_versionlink
    Versionlink.create_versionlink(language, prod_key, version, @podspec.homepage, 'Homepage')
  end

  def create_github_podspec_versionarchive
    # checking for valid link is done inside create_versionlink
    archive = Versionarchive.new({
      language: language,
      prod_key: prod_key,
      version_id: version,
      link: "#{base_url}/blob/master/Specs/#{name}/#{version}/#{name}.podspec.json",
      name: "#{name}.podspec",
    })
    Versionarchive.create_archive_if_not_exist( archive )
  end

  def create_screenshot_links
    @podspec.screenshots.to_enum.with_index(1).each do |img_url, i|
      Versionlink.create_versionlink(language, prod_key, version, img_url, "Screenshot #{i}")
    end
  end

  def description
    description = @podspec.summary
    if @podspec.description
      description << "\n\n" << @podspec.description
    end
    description
  end

end
