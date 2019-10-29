#!/usr/bin/env ruby

STDOUT.sync = true

require 'fileutils'
require 'json'
require 'net/http'
require 'uri'
require 'yaml'
require 'erb'
require 'pathname'

require_relative '../lib/wardrobe/codeowners'
require_relative '../lib/wardrobe/github'
require_relative '../lib/wardrobe/helper'

token = ENV['GITHUB_TOKEN'].to_s
raise "GITHUB_TOKEN must be set" if token.empty?

def get_links(header)
  links = {}
  if header
    header.scan(/<([^>]+)>;\s*rel="([^"]+)"/).each do |match|
      links[match[1]] = match[0]
    end
  end
  return links
end

def all_repos(token)
  uri = "https://api.github.com/orgs/roivant/repos?access_token=#{token}"
  while uri do
    response = Net::HTTP.get_response(URI.parse(uri))

    parsed = JSON.parse(response.body)
    parsed.each do |repos|
      yield repos
    end

    links = get_links(response['link'])
    uri = links['next']
  end
end

def has_repository_metadata(org, repos, token)
  uri = "https://api.github.com/repos/#{org}/#{repos}/contents/repository_metadata.yaml?access_token=#{token}"

  return Net::HTTP.get_response(URI.parse(uri)).is_a? Net::HTTPOK
end

def in_each_repo_dir(token)
  skips = [
    /gold.*path/,   # Golden paths should be rebuilt, not updated
    /infra-global/, # Don't touch specific Infrastructure things for now
    /generic-vant/, # Don't touch specific Infrastructure things for now
  ]

  skip_by_name = {}
  begin
    File.open('repos.skip') do |fh|
      fh.readlines.each do |line|
        skip_by_name[line.strip] = true
      end
    end
  rescue Exception => ex
    puts "Failed to find repos.skip"
  ensure
    system "touch repos.skip"
  end

  FileUtils.mkdir_p "#{ENV['HOME']}/repositories"
  Dir.chdir "#{ENV['HOME']}/repositories" do
    all_repos(token) do |repo|
      # This is so we can handle skips within a loop. This is (roughly)
      # equivalent to "next LABEL" in other languages.
      catch :skip do
        org  = repo['owner']['login']
        name = repo['name']

        if skip_by_name[name]
          puts "Skipping #{org}/#{name}"
          next
        end

        skips.each {|regex| throw :skip if name.match regex }
        next unless has_repository_metadata(org, name, token)
        if File.directory? name
          system %Q{
            cd #{name} &&
            git reset --hard -q HEAD &&
            git checkout -q master &&
            git pull -q
          }
        else
          system %Q{hub clone #{org}/#{name}}
        end

        Dir.chdir name do
          yield org, name, repo
        end
      end
    end
  end
end

def create_branch(branch)
  system %Q{git checkout -q -b #{branch}}
end

def remove(files)
  system %Q{git ls-files '#{files}' | xargs git rm}
end

def apply_and_add(files, command)
  system %Q{git ls-files -- '#{files}' | xargs #{command}}
  system %Q{git ls-files -- '#{files}' | xargs git add}
end

def commit_push_pr(branch, message, reviewer)
  system %Q{git commit -q -m "#{message}"}
  system %Q{git push -q -u origin #{branch} | grep -v '^remote:'}
  system %Q{hub pull-request -m "#{message}" -r #{reviewer}}
end

def change_after(file:, anchor:, new:, match: '.*', lines_after: 1)
  newlines = 'n;' * lines_after
  system %Q{
    sed -i '/#{anchor}/{#{newlines}s/#{match}/#{new}/}' #{file}
  }
end

def validate_app_role(name, target_file)
  file_change = nil
  puts
  puts "working on #{name}"
  name = name.gsub(/[^0-9A-Za-z_]+/, '_')

  unless File.foreach(target_file).grep(/app:/).any?
    puts 'No app hash exists...'
    puts 'Writing new default attribute app: {name: }'
    new =  %Q{\\ \\ app: {\\n\\t  name: '#{name}',\\n  },}
    anchor = "default_attributes("
    file_change = %Q{sed -i "/#{anchor}/a #{new}" #{target_file}}
  else
    unless File.foreach(target_file).grep(/name:/).any?
      puts 'Found app hash with no name hash'
      needs_change = true
      new =  %Q{\\ \\ \\ \\ name: '#{name}',}
      anchor = "app: {"
      file_change = %Q{sed -i "/#{anchor}/a #{new}" #{target_file}}
    else
      puts 'Found an app and name hash...'
      puts 'Nothing to do here...'
    end
  end
  return file_change
end

################################################################################

def devops_1115(token)
  in_each_repo_dir(token) do |org, name, repo|
    # Count the number of files named "boilerplate.tf" anywhere in the repo
    # that have "tflock-" followed by something that isn't "terraform".
    count = %x{
      git grep -lP 'tflock-(?!terraform)' -- */boilerplate.tf | wc -l
    }.chomp.to_i
    next if count == 0

    branch = "DEVOPS-1115/use_common_tflock"
    create_branch(branch)

    apply_and_add(
      '*/boilerplate.tf',
      %q{perl -pi -e 's/"tflock-[^"]*"/"tflock-terraform"/'},
    )

    commit_push_pr(branch, "Use common tflock", 'roivant/devops')
  end
end

def halo_214(token)
  in_each_repo_dir(token) do |org, name, repo|
    puts "Checking #{org}/#{name}"
    files = '*/boilerplate.tf'
    count = %x{
      git ls-files '#{files}' | wc -l
    }.chomp.to_i
    next if count == 0

    branch = 'HALO-214/delete-boilerplate-tf-files'
    create_branch(branch)
    remove(files)
    commit_push_pr(branch, 'HALO-214/Remove boilerplate.tf', 'roivant/devops')
  end
end

def devops_1179(token)
  in_each_repo_dir(token) do |org, name, repo|
    # We only care if this project has a Packer DSL file in devops/packaging
    # that has the string "json({" ending a line and "python" beginning the next
    # grep -Pzo allows us to search across line boundaries.
    count = %x[
      git ls-files devops/packaging/*.dsl | xargs grep -Pzo 'json\\({\\n\\s+python' | wc -l
    ].chomp.to_i
    puts count
    next if count == 0

    branch = "DEVOPS-1179/pass-scm-repository-in-packer"
    create_branch(branch)

    # perl -i (inplace editing) -p0 (slurp whole file and print result)
    # "s/<match>/<replacement>/s" (/s makes '.' match newlines as well)
    apply_and_add(
      'devops/packaging/*.dsl',
      %q[perl -i -p0 -e "s/json\({.\s{8}python/json({\n        scm_repository: '{{ \`scm_repository\`}}',\n        python/s"],
    )

    commit_push_pr(branch, "Pass scm_repository to Chef in Packer", 'roivant/devops')
  end
end

def devops_1251(token)
  repometa = 'repository_metadata.yaml'

  in_each_repo_dir(token) do |org, name, repo|
    # We only care if this project doesn't not have a billing_entity set within
    # the repository_metadata.yaml file.

    # Some repometa files aren't parseable YAML. Fix known issues.
    # * owner has a @ without quoting
    system %Q{perl -pi -e 's/owner: \@(.*)/owner: "\@\\1"/' #{repometa}}

    meta = YAML::load_file(repometa)

    # YAML::load will load a file it cannot parse as a string. These are the
    # common situations where the YAML file is wrong. Fix known issues:
    # owner:foobar
    if meta.is_a? String
      meta = YAML::load(meta.gsub(/:/, ': '))
    end

    next if meta['billing_entity']

    branch = "DEVOPS-1251/add-billing-entity"
    create_branch(branch)

    meta['billing_entity'] =
      case meta['owner']
      when /devops/, /lindahl/, /sinan/, /palmier/, /kinyon/, /rudokas/, /middleton/, 'elx-martin', /foy/
        'devops'
      when /datawarehouse/, /pshort05/
        'data_architecture'
      when 'kaminoff'
        'infrastructure'
      when 'loopasam', 'juliagray'
        'compres' # This one isn't in the list of allowed, but is still correct.
      when /salesrep/, /alyvant/
        'alyvant'
      when /theodoredasher/i, /mitchell/i, /broyde/i, /elliotmonster/i
        'alyvant'
      else
        case name # This is the repository name
        when /alyvant/
          'alyvant'
        when /droid/
          'data_architecture'
        else
          'digital_innovation'
        end
      end

    File.open(repometa, 'w') do |file|
      file.write(meta.to_yaml)
    end
    system %Q{git add #{repometa}}

    commit_push_pr(branch, "Add billing_entity", 'roivant/devops')
  end
end

def devops_1299(token)
  in_each_repo_dir(token) do |org, name, repo|
    # We only want to add a new line *.xls* to .gitignore
    # to prevent committing Excel files in the wardrobe branch

    next if system('grep', '-q', '*.xls*', '.gitignore')

    branch = "DEVOPS-1299/Ignore-excel-files-by-default"
    create_branch(branch)

    lines = "# Ignore Excel files\n*.xls*\n"

    system "echo '#{lines}' >> .gitignore"
    system "git add .gitignore"

    commit_push_pr(branch, "DEVOPS-1299/Ignore Excel files by default", 'roivant/devops')
  end
end

def devops_1608(token)
  in_each_repo_dir(token) do |org, name, repo|
    next unless File.exists?('Gemfile') && File.directory?('devops/tasks')
    next unless system('grep -q tasks Gemfile') ||
      system('grep -q Dev::Bundler devops/tasks/*.rake')

    branch = "DEVOPS-1608/remove-gemfile"
    create_branch(branch)

    system "sed -i '/Dev::Bundler/d' devops/tasks/dev.rake"
    system "sed -i '/dev\\/bundler/d' devops/tasks/dev.rake"
    system "git add devops/tasks/dev.rake"

    system "git rm -f Gemfile Gemfile.lock"

    # Reset the Jenkinsfile to a base state without 'bundle install'
    # Squiggly-HEREDOC intelligently strips leading whitespace.
    IO.write('Jenkinsfile', <<~CONTENT)
      pipeline {
        agent {
          // This is a label used by the Jenkins master to determine which agent can build your project.
          // https://wiki.jenkins.io/display/JENKINS/Distributed+builds#Distributedbuilds-Nodelabelsforagents
          label 'lxc'
        }
        stages {
          stage('Test') {
            steps {
              sh 'rake test:all'
            }
          }
        }
        post {
          always {
            // always clean up your workspace
            sh 'rake dev:destroy'
            cleanWs()
          }
        }
      }
    CONTENT
    system "git add Jenkinsfile"

    commit_push_pr(branch, "DEVOPS-1608/remove-gemfile", 'roivant/devops')
  end
end

def devops_1224(token)
  include Wardrobe::Codeowners
  include Wardrobe::GitHub

  person_to_team = {
    'aviswanath4'          => 'digitalinnovators',
    'dannykovtun'          => 'digitalinnovators',
    'devops'               => 'devops',
    'EmirHaskovicROI'      => 'digitalinnovators',
    'elx-martin'           => 'devops',
    'emmagalgano'          => 'digitalinnovators',
    'egalgano'             => 'digitalinnovators',
    'harp-roi'             => 'digitalinnovators',
    'houstonwarren'        => 'digitalinnovators',
    'JBRoivant'            => 'alyvant',
    'kaminoff'             => 'infrastructure',
    'maddieweiner-roivant' => 'digitalinnovators',
    'markroivant'          => 'digitalinnovators',
    'michelleguo92'        => 'digitalinnovators',
    'MitchellMittman'      => 'alyvant',
    'rajatsc4'             => 'digitalinnovators',
    'ravinajain'           => 'digitalinnovators',
    'ravina.jain'          => 'digitalinnovators',
    'roi-terrydontje'      => 'salesrep-developers',
    'roivant-briandfoy'    => 'devops',
    'rperez4'              => 'infrastructure',
    'SohumKaji'            => 'digitalinnovators',
    'TheodoreDasherROI'    => 'alyvant',
    'udaysuresh'           => 'digitalinnovators',
  }

  in_each_repo_dir(token) do |org, name, repo|
    next unless codeowners_file

    people = []
    team = nil
    codeowners.each do |spec, owners|
      # Some of the owners are separated by "," which is wrong
      owners.map! {|o| o.gsub /,/, ''}

      # Some of the owners have the prepended @ symbol
      owners.map! {|o| o.gsub /@/, ''}

      owners.each do |person|
        if person.match /<github/
          people.push person
          team = 'digitalinnovators'
          break
        end

        # This is already a team. Nothing to do with this one.
        next if person.split('/').length >= 2

        people.push person
        new_team = person_to_team[person]
        if ! team
          team = new_team
        elsif team != new_team
          raise "Too many teams for #{name}\n\t#{people.sort.join', '}"
        end
      end
    end

    # There are no people to convert into teams.
    next if people.empty?

    unless team
      if name.match /alyvant/i
        team = 'alyvant'
      else
        raise "Cannot find team for #{name}"
      end
    end

    puts "Working on #{name}"

    branch = "DEVOPS-1224/codeowners-are-teams"
    create_branch(branch)

    final_file = []
    wrote_team = false
    File.foreach(codeowners_file) do |line|
      if line.match /^\s*\*\s+@?(.*)/
        unless wrote_team
          line = "* @roivant/#{team}\n"
          wrote_team = true
        else
          next
        end
      end

      final_file.push line
    end

    # This part ensures that the CODEOWNERS file is moved to .github/CODEOWNERS
    FileUtils.rm_f codeowners_file
    FileUtils.mkdir_p '.github'
    File.write('.github/CODEOWNERS', final_file.join(''))

    system "git add #{codeowners_file}"

    unique_codeowners.each do |owner|
      org, team = owner.split '/'
      raise "#{owner} is not a team" unless team

      ensure_team_write(
        github_client(token),
        "roivant/#{name}",
        team,
      )
    end

    commit_push_pr(branch, "All owners must be teams", 'roivant/devops')
  end
end

def devops_1745(token)
  in_each_repo_dir(token) do |org, name, repo|
    next unless File.exist?('Vagrantfile')
    puts "working on #{name}"

    branch = "DEVOPS-1745/use-latest-version-of-devops-vagrant"
    create_branch(branch)

    # There is more than one way the vagrant version is declared.
    # So, two commands needed to change the checked version.
    system "sed -i \"s/^MINIMUM_DEVOPS_VAGRANT.*/MINIMUM_DEVOPS_VAGRANT = '0.0.31'/\" Vagrantfile"
    system "sed -i \"s/Gem\:\:Version\.create\(\'0\.0.*/Gem::Version.create('0.0.31')/\" Vagrantfile"

    commit_push_pr(branch, "Bump required version of devops-vagrant", 'roivant/devops')
  end
end

def devops_1779(token)
  require_relative './lib/devops1779.rb'

  branch = Wardrobe::Devops1779.branch_name
  commit_msg = Wardrobe::Devops1779.commit_msg
  reviewer = Wardrobe::Devops1779.reviewer

  in_each_repo_dir(token) do |org, name, repo|
    handler = Wardrobe::Devops1779.new
    if handler.dsl_files.length > 0
      puts "Working on #{name}"
      create_branch(branch)
      if handler.ensure_region_in_ebs_builder()
        commit_push_pr(branch, commit_msg, reviewer)
      end
    end
  end
end

def devops_1784(token)
  in_each_repo_dir(token) do |org, name, repo|
    next unless File.exist? 'Berksfile'

    puts "Working on #{name}"

    branch = "DEVOPS-1784/upgrade-apache-2.4.39"
    create_branch(branch)

    # Instead of trying to figure out how to edit the line, let's just delete it
    # and add back the line we want.
    system %Q[ sed -i "/'roivant'/d" Berksfile ]
    system %Q[ echo "cookbook 'roivant', '>= 0.0.72'" >> Berksfile ]

    # Update the lockfile
    if File.exist? 'Berksfile.lock'
      system "berks update"
    else
      system "berks install"
    end
    system "git add Berksfile*" # This also adds the lockfile

    # Update the recipes in the role
    Dir.glob('devops/provisioning/chef/roles/*.rb').each do |path|
      %w[apache2 supervisord].each do |name|
        system %Q{sed -i "s/recipe\\[#{name}\\]/recipe\\[roivant::#{name}\\]/" #{path}}
      end
      system "git add #{path}"
    end

    commit_push_pr(branch, "Upgrade Apache to 2.4.39", 'roivant/devops')
  end
end

def devops_1991(token)
  require_relative './lib/devops1991.rb'

  branch = Wardrobe::Devops1991.branch_name
  commit_msg = Wardrobe::Devops1991.commit_msg
  reviewer = Wardrobe::Devops1991.reviewer

  in_each_repo_dir(token) do |org, name, repo|
    handler = Wardrobe::Devops1991.new
    next unless handler.needs_to_run?

    puts "Working on #{name}"

    begin
      puts "create_branch(#{branch})"
      create_branch(branch)
    rescue Exception => ex
      puts "Failed to create '#{branch}' branch: #{ex}"
    ensure
      system "git checkout #{branch}"
    end

    files_modified = handler.run
    files_modified.each do |file|
      puts "git add #{file}"
      system "git add #{file}"
    end

    begin
      puts "commit_push_pr(#{branch}, #{commit_msg}, #{reviewer})"
      commit_push_pr(branch, commit_msg, reviewer)
    rescue Exception => ex
      puts "Failed to commit, push, and create PR for #{org}/#{name}: #{ex}"
    end
  end
end

def devops_2277(token)
  in_each_repo_dir(token) do |org, name, repo|

    next unless File.exist? 'Berksfile'

    puts "working on #{name}"

    branch = "DEVOPS-2277/propagate-new-artifactory-chef"
    create_branch(branch)

    #This is to propagate the chef artifactory credentials.
    system %Q[ sed -z "s|https://artifactory.vant.com/artifactory/api/chef/cookbooks|https://7983eb7c5a62303ba6d42205a5a8e891:16c2ee68a2b4ab75b73b272db704e0bd@artifactory.vant.com/artifactory/api/chef/cookbooks|" Berksfile]
    system "git add Berksfile"

    if File.exist? 'Berksfile.lock'
      system "berks update"
    else
      system "berks install"
    end
    system "git add Berksfile.lock"

    commit_push_pr(branch, "DEVOPS-2277/propagate-new-artifactory-chef", 'roivant/devops')
  end
end

def halo_384(token)
  require 'find'

  in_each_repo_dir(token) do |org, name, repo|

    cloud_init_templates = []
    instance_terraforms = []
    # find if there are templates to update
    if File.exist?('devops/infra/terraform')
      Find.find('devops/infra/terraform') do |path|
        cloud_init_templates << path if path =~ /.*\.tpl$/
      end
      # we have a template, find if there is a tf feeding it.
      Find.find('devops/infra/terraform') do |path|
        instance_terraforms << path if path =~ /.*\.tf$/ and File.readlines(path).grep(/"template_file"/).any?
      end
    end

    if instance_terraforms.empty? or cloud_init_templates.empty?
      puts " - #{name}: skipping."
      next
    end

    branch = "HALO-384/populate-deployed-env-in-tf"
    create_branch(branch)

    puts " * Updating #{name}"

    instance_terraforms.each do | tf_file |
      puts "updating #{tf_file}"
      in_template_resource = false
      new_contents = []
      # It'd take forever for me to devise a regex to do this, so looping to replace
      # the environment_name ONLY if its in a data.template_file block.
      File.foreach(tf_file) do |line|
        if line.match /^data "template_file"/
          in_template_resource = true
        end
        if line.match /^}/ and in_template_resource
          in_template_resource = false
        end
        if line.match /environment_name[ ]*=[ ]*/ and in_template_resource
          line = line.gsub(/environment_name[ ]*=[ ].*$/, 'environment_name = "${var.environment_name == "Production" ? "prod" : var.environment_name}"')
        end
        new_contents.push line
      end
      File.write(tf_file, new_contents.join(''))
      system %Q[ git add #{tf_file} ]
    end
    cloud_init_templates.each do | tpl_file |
      puts "updating #{tpl_file}"
      system %Q[ sed -i '/<< EOF/a export DEPLOYED_ENVIRONMENT="${environment_name}"' #{tpl_file} ]
      system %Q[ git add #{tpl_file} ]
    end

    # Update the lockfile
    if File.exist? 'Berksfile.lock'
      system "berks update"
    else
      system "berks install"
    end
    system "git add Berksfile*" # This also adds the lockfile

    system "git --no-pager diff origin"  # see the damage in one spot

    commit_push_pr(branch, "HALO-384/pass deployed env to cloud-init", 'roivant/devops')
  end
end

# Inserts run_tag elements above tag elements in the
#packer amazon_ebs elements
def halo_513(token)
  require_relative './lib/halo513.rb'
  token = ENV['GITHUB_TOKEN'] if token.to_s == ""

  branch = Wardrobe::Halo513.branch_name
  commit_msg = Wardrobe::Halo513.commit_msg
  reviewer = Wardrobe::Halo513.reviewer

  in_each_repo_dir(token) do |org, name, repo|
    handler = Wardrobe::Halo513.new
    next unless handler.needs_to_run?
    puts "Working on #{name}"

    begin
      puts "create_branch(#{branch})"
      create_branch(branch)
    rescue Exception => ex
      puts "Failed to create '#{branch}' branch: #{ex}"
    ensure
      system "git checkout #{branch}"
    end

    files_modified = handler.update_dsl_files
    files_modified.each do |file|
      puts "git add #{file}"
      system "git add #{file}"
    end

    begin
      next unless !files_modified.empty?
      puts "commit_push_pr(#{branch}, #{commit_msg}, #{reviewer})"
      commit_push_pr(branch, commit_msg, reviewer)
    rescue Exception => ex
      puts "Failed to commit, push, and create PR for #{org}/#{name}: #{ex}"
    end
  end
end

def halo_93(token)
  include Wardrobe::Helper
  repometa = 'repository_metadata.yaml'
  in_each_repo_dir(token) do |org, name, repo|
    meta = YAML::load_file(repometa)

    # This will insert or override, as appropriate. We want to own This
    # value, so it doesn't matter what was there before.
    meta['application_name'] = appname_from_repo_name(name)

    File.open(repometa, "w") do |file|
      file.write(meta.to_yaml)
    end

    branch = "HALO-93/add-app-name-to-repometa"
    create_branch(branch)

    system "git add #{repometa}"
    commit_push_pr(branch, "HALO-93/add application name to repometa file", 'roivant/devops')
  end
end

def halo_812(token)
  require_relative './lib/halo812.rb'

  branch = Wardrobe::Halo812.branch_name
  commit_message = Wardrobe::Halo812.commit_message
  reviewer = Wardrobe::Halo812.reviewer

  in_each_repo_dir(token) do |org, name, repo|
    handler = Wardrobe::Halo812.new(name)

    changed = [
      *handler.update_berksfile,
      *handler.update_vagrantfile,
      *handler.update_pipfile_lock,
    ].reject { |path| path.nil? }

    next if changed.empty?

    puts "Working on #{name}"
    create_branch(branch)

    changed.each do |path|
      unless system 'git', 'add', path.to_s
        raise "Failed to add #{path}: $?"
      end
    end

    commit_push_pr(branch, commit_message, reviewer)
    puts "[HALO-812 in #{name}] OK"
  end
end

def halo_521(token)
  codeowners_template = "../templates/python-flask/.github/CODEOWNERS.wardrobe-tmpl"
  erb = ERB.new(File.read(codeowners_template))
  in_each_repo_dir(token) do |org, name, repo|
    full_name = "#{org}/#{name}"
    branch = 'HALO-521/Jointly-own-lock-files'
    commit_message = 'HALO-521/Jointly own lock files'

    codeowners_path = nil
    ['.github/CODEOWNERS', 'CODEOWNERS'].each do |p|
      if File.exists?(p)
        codeowners_path = p
        break
      end
    end

    if codeowners_path.nil?
      puts "[HALO-521]: Could not find a CODEOWNERS file in repo: #{name}"
      next
    end

    owner = nil

    begin
      File.readlines(codeowners_path).each do |line|
        line.match(/^\*\s+(\S+)/) { |m|
          owner = m[1]
          break
        }
      end
    rescue StandardError => e
      puts "[HALO-521]: Failed to read #{codeowners_path} in repo: #{name} : #{e.message}"
    end

    if owner.nil?
      puts "[HALO-521]: Failed to parse owner in #{codeowners_path} in repo: #{name}"
      return
    end

    begin
      create_branch(branch)
      # During a dry run we forget to deactivate the
      # create_branch below, so some repos will already have this branch. If
      # that's the error, that's OK, swallow the exception and move on.
    rescue StandardError => e
      unless e.message.match?(/already exists\z/)
        raise e
      end
    end

    IO.write(codeowners_path, erb.result(binding))
    system "git add #{codeowners_path}"
    commit_push_pr(branch, commit_message, 'roivant/devops')
  end
end

def halo_1013(token)
  in_each_repo_dir(token) do |org, name, repo|
    next unless Dir.exist? 'devops/infra/terraform/network'

    puts "Working on #{name}"

    branch = "HALO-1013/update-to-multistack-capable"
    create_branch(branch)

    # Need to apply all changes *EXCEPT* the change to security groups. So:
    # * alb-alert.tf
    # * error-log-metric.tf
    # * main.tf
    #   - resourcegroups_group.name
    #   - cloudwatch_log_group.name
    #   - instance_profile.name
    # * sns.tf

    if File.exist? 'devops/infra/terraform/network/main.tf'
      change_after(
        file: 'devops/infra/terraform/network/main.tf',
        anchor: 'aws_resourcegroups_group',
        new: %q{  name = "${var.application_name}-${var.environment_name}"},
      )
      change_after(
        file: 'devops/infra/terraform/network/main.tf',
        anchor: 'aws_cloudwatch_log_group',
        new: %q{  name = "${var.application_name}-${var.environment_name}"},
      )
      change_after(
        file: 'devops/infra/terraform/network/main.tf',
        anchor: 'aws_iam_instance_profile',
        new: %q{  name = "${var.application_name}-${var.environment_name}"},
      )
    end

    if File.exist? 'devops/infra/terraform/network/alb-alert.tf'
      change_after(
        file: 'devops/infra/terraform/network/alb-alert.tf',
        anchor: '"aws_cloudwatch_metric_alarm" "alb-target-5xx"',
        lines_after: 1,
        new: %q{  alarm_name        = "${var.application_name}-${var.environment_name}-alb-target-5xx"},
      )
      change_after(
        file: 'devops/infra/terraform/network/alb-alert.tf',
        anchor: '"aws_cloudwatch_metric_alarm" "alb-target-5xx"',
        lines_after: 2,
        new: %q{  alarm_description = "Monitor target 5xx errors for ${var.application_name}-${var.environment_name}"},
      )
    end

    if File.exist? 'devops/infra/terraform/network/error-log-metric.tf'
      change_after(
        file: 'devops/infra/terraform/network/error-log-metric.tf',
        anchor: '"aws_cloudwatch_metric_alarm" "application_error"',
        new: %q{  alarm_description = "Monitor ERROR messages in application log for ${var.application_name}-${var.environment_name}"},
      )
    end

    if File.exist? 'devops/infra/terraform/network/sns.tf'
      change_after(
        file: 'devops/infra/terraform/network/sns.tf',
        anchor: '"aws_sns_topic" "default"',
        new: %q{  name = "${var.application_name}-${var.environment_name}"},
      )
    end

    commit_push_pr(branch, "HALO-1013: Update to make ths project multistack-capable", 'roivant/devops')
  end
end

def halo_926(token)
  require_relative './lib/halo926.rb'

  current_wardrobe_dir = Pathname.new(File.expand_path("../../", __FILE__))

  # This creates the full path to the base terraform directory
  full_base_terraform_location = Pathname.new(File.expand_path("../../templates/python-flask/devops/infra/terraform/base", __FILE__))

  overwrite_files_wardrobe = [
    'templates/python-flask/devops/infra/terraform/network/main.tf',
    'templates/python-flask/devops/infra/terraform/network/variables.tf',
    'templates/python-flask/devops/infra/terraform/serverless-instances/inputs.tf',
    'templates/python-flask/devops/infra/terraform/serverless-instances/main.tf',
    'templates/python-flask/devops/infra/terraform/serverless-instances/outputs.tf',
    'templates/python-flask/devops/infra/terraform/serverless-network/main.tf',
    'templates/python-flask/devops/infra/terraform/serverless-network/outputs.tf',
    'templates/python-flask/devops/infra/terraform/serverless-network/inputs.tf',
  ]

  branch = Wardrobe::Halo926.branch_name
  commit_message = Wardrobe::Halo926.commit_message
  reviewer = Wardrobe::Halo926.reviewer

  in_each_repo_dir(token) do |org, name, repo|
    handler = Wardrobe::Halo926.new

    # lets go ahead and delete the server and serverless folders before we continue
    # They are not in use and will be overwritten anyway
    handler.delete_existing_serverless_terraform_folders

    # check if project has infra dir, a deploy.rake file,
    # and if it already has an IAM role
    next unless handler.all_files_exist_in_repo? && handler.repo_does_not_have_iam_role?

    puts "[HALO-926 in #{name}] OK"

    create_branch(branch)

    changed_files = ['devops/tasks/deploy.rake']

    # This will add the passed in directory along with its files to the infra folder in a project
    # Essential specifying which terraform directory needs to be moved, and then moves it
    changed_files |= handler.add_base_terraform_to_repo(full_base_terraform_location)

    # This will overwrite specific files within the projects directory with
    # files specified in wardrobe. If the folder/files don't exist,
    # it will create them
    changed_files |= handler.add_to_existing_terraform(current_wardrobe_dir, overwrite_files_wardrobe)

    # This will make edits to the deploy.rake to sections that will exist in every project currently
    handler.edit_deploy_rake_file

    handler.modify_modality_selection_to_deploy_rake_file

    # This will replace the project implementation of the infra terraform
    # with the one set in a variable
    handler.add_modality_selection_to_deploy_rake_file

    # This will add the serverless and base var_maps
    # It will delete any that exist and just re-add
    handler.add_serverless_var_maps

    changed_files.each do |path|
      unless system 'git', 'add', path.to_s
        raise "Failed to add #{path}"
      end
    end

    commit_push_pr(branch, commit_message, reviewer)

  end
end

#####################
def halo_1122(token)
  require 'find'
  target_file = 'devops/provisioning/chef/roles/application.rb'
  in_each_repo_dir(token) do |org, name, repo|
    next unless File.exist? target_file
    file_change = validate_app_role(name, target_file)

    next unless file_change
    branch = "HALO-1122/get-appname-from-repometa-dev-prod"
    commit_message = 'HALO-1122/ensure appname is in default attributes'
    puts "Would have added and committed change to #{name} but waiting for approval..."
    create_branch(branch)
    system file_change
    system %Q{git add #{target_file}}
    commit_push_pr(branch, commit_message, 'roivant/devops')
  end
end

def halo_603(token)
  branch = "HALO-603/scm_repository_in_deploy_rake"
  commit_message = "HALO-603/updating scm repository in deploy.rake"
  reviewer = 'roivant/devops'
  token = ENV['GITHUB_TOKEN'] if token.to_s == ""
  in_each_repo_dir(token) do |org, name, repo|
    next unless system "git grep -q current_project_id devops/tasks/deploy.rake"
    create_branch(branch)
    puts "working on '#{name}'"
    begin
      system "sed -i '/scm_repository:/d' devops/tasks/deploy.rake"
      system "git add devops/tasks/deploy.rake"
      puts "commit_push_pr(#{branch}, #{commit_message}, #{reviewer})"
      commit_push_pr(branch, commit_message, reviewer)
    rescue Exception => ex
      puts "Failed to commit, push, and create PR for #{org}/#{name}: #{ex}"
    end
  end
end

def halo_1354(token)
  include Wardrobe::GitHub
  target_file = 'Jenkinsfile'
  failed_repos = []
  in_each_repo_dir(token) do |org, name, repo|
    puts "working on '#{name}'"
    # Remove Jenkins webhook if it exists
    client = github_client(token)
    hooks = client.hooks("#{org}/#{name}")
    did_succeed = true
    hooks.each do |hook|
      hook_url = hook[:config]['url']
      next unless hook_url.include? "jenkins"
      did_succeed = client.remove_hook("#{org}/#{name}", hook[:id])
      unless did_succeed
        puts "Failed to remove #{hook_url} from #{name}"
        failed_repos.push(name)
      else
        puts "Successfully removed #{hook_url} from #{name}"
      end
    end
    # Remove Jenkinsfile if it exists
    next unless File.exist? target_file || did_succeed
    branch = "HALO-1354/disconnect-jenkins-from-github"
    commit_message = 'HALO-1354/disconnect Jenkins from Github'
    create_branch(branch)
    system %Q{git rm #{target_file}}
    commit_push_pr(branch, commit_message, 'roivant/devops')
  end

  unless failed_repos.empty?
    puts "NOTE: could not remove the Jenkins webhook and skipped the Jenkinsfile in the following repos\n"
    puts "#"*10 + "\n#{failed_repos.join("\n")}" + "#"*10
  end
  return failed_repos
end
############################################################################
# Here is where you manually put the command to run, then remove it before
# committing.

puts "Ok"
