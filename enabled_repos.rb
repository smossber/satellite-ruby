#!/usr/bin/env ruby

# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
# MA 02110-1301, USA.
#
#
# Sample framework based on katello-cvmanager (https://github.com/RedHatSatellite/katello-cvmanager/)

require 'optparse'
require 'yaml'
require 'apipie-bindings'
require 'highline/import'
require 'time'
require 'logging'
require 'awesome_print'
require 'rest-client'
require 'csv'

@defaults = {
  :noop        => false,
  :keep        => 5,
  :uri         => 'https://someHost',
  :timeout     => 300,
  :user        => 'admin',
  :pass        => '',
  :org         => "1",
  :lifecycle   => 1,
  :force       => false,
  :wait        => false,
  :sequential  => 0,
  :promote_cvs => false,
  :checkrepos  => false,
  :verbose     => false,
  :description => 'autopublish',
  :verify_ssl  => false,
}

@options = {
  :yamlfile  => 'hostgroups.yaml',
}

optparse = OptionParser.new do |opts|
  opts.banner = "Usage: #{opts.program_name} ACTION [options]"
  opts.version = "0.1"

  opts.on("-U", "--uri=URI", "URI to the Satellite") do |u|
    @options[:uri] = u
  end
  opts.on("-t", "--timeout=TIMEOUT", OptionParser::DecimalInteger, "Timeout value in seconds for any API calls. -1 means never timeout") do |t|
    @options[:timeout] = t
  end
  opts.on("-u", "--user=USER", "User to log in to Satellite") do |u|
    @options[:user] = u
  end
  opts.on("-p", "--pass=PASS", "Password to log in to Satellite") do |p|
    @options[:pass] = p
  end
  opts.on("-c", "--output-csv-file=FILE", "/path/to/file where to save the repo set csv") do |file|
    @options[:output_csv_file] = file
  end
  opts.on("-y", "--output-yaml-file=FILE", "/path/to/file where to save the repo set csv") do |file|
    @options[:output_yaml_file] = file
  end
  opts.on("-o", "--organization-id=ID", "ID of the Organization to manage CVs in") do |o|
    @options[:org] = o
  end
  opts.on("-n", "--noop", "do not actually execute anything") do
    @options[:noop] = true
  end
  opts.on("-v", "--verbose", "Get verbose logs from cvmanager") do
    @options[:verbose] = true
  end
  opts.on("--very-verbose", "Get very verbose logs") do
    @options[:very_verbose] = true
    @options[:verbose] = true
  end
  opts.on("--no-verify-ssl", "don't verify SSL certs") do
    @options[:verify_ssl] = false
  end
end
optparse.parse!

#if ARGV.empty?
#  puts optparse.help
#  exit
#end


@defaults.each do |key,val|
  if not @options.has_key?(key)
    @options[key] = val
  end
end

# Ask for Satellite username and password
if not @options[:user]
  @options[:user] = ask('Satellite username: ')
end

if not @options[:pass]
  @options[:pass] = ask('Satellite password: ') { |q| q.echo = false }
end


# Set up the connection
# Uses username and password
if @options[:very_verbose]
	puts "VERY VERBOSE INDEEEED"
	@api = ApipieBindings::API.new({:uri => @options[:uri], :username => @options[:user], :password => @options[:pass], :api_version => '2', :timeout => @options[:timeout], :logger => Logging.logger(STDOUT)}, {:verify_ssl => @options[:verify_ssl]})
else
	@api = ApipieBindings::API.new({:uri => @options[:uri], :username => @options[:user], :password => @options[:pass], :api_version => '2', :timeout => @options[:timeout]}, {:verify_ssl => @options[:verify_ssl]})
end


def puts_verbose(message)
  if @options[:verbose]
    puts "    [VERBOSE] #{message}"
  end
end


def get_all_products
  products = []
  req = @api.resource(:products).call(:index, {:organization_id => @options[:org], :enabled => true,:full_results => true})
  products.concat(req['results'])
  while (req['results'].length == req['per_page'].to_i)
    req = @api.resource(:products).call(:index, {:organization_id => @options[:org], :enabled => true,:full_results => true, :per_page => req['per_page'], :page => req['page'].to_i+1})
    products.concat(req['results'])
  end
  return products
end
def get_product_by_id(id)
  hostgroups = []
  product = @api.resource(:hostgroups).call(:show, {:organization_id => @options[:org], :full_results => true,:id => id})
  return hostgroup
end
def get_all_repository_sets(product_id)
  repository_set = []
  req = @api.resource(:repository_sets).call(:index, {:organization_id => @options[:org],:product_id => product_id ,:full_results => true})
  repository_set.concat(req['results'])
  while (req['results'].length == req['per_page'].to_i)
p
    req = @api.resource(:repository_sets).call(:index, {:organization_id => @options[:org], :product_id => product_id, :full_results => true, :per_page => req['per_page'], :page => req['page'].to_i+1})
    repository_set.concat(req['results'])
  end
  return repository_set
end

def get_all_enabled_repositories(product_id)
  repositories = []
  req = @api.resource(:repositories).call(:index, {:organization_id => @options[:org], :enabled => true, :product_id => product_id, :full_results => true})
  repositories.concat(req['results'])
  while (req['results'].length == req['per_page'].to_i)
    req = @api.resource(:repositories).call(:index, {:organization_id => @options[:org], :enabled => true, :product_id => product_id, :full_results => true, :per_page => req['per_page'], :page => req['page'].to_i+1})
    repositories.concat(req['results'])
  end
  return repositories
end
def get_repository_set_repos(product_id, repo_set_id)
  repository = []
  req = @api.call(:repository_sets, :available_repositories , {:organization_id => @options[:org],:product_id => product_id, :id => repo_set_id,:full_results => true})
  repository.concat(req['results'])
  while (req['results'].length == req['per_page'].to_i)
    req = @api.call(:repository_sets, :available_repositories, {:organization_id => @options[:org],:product_id => product_id, :id => repo_set_id,  :full_results => true, :per_page => req['per_page'], :page => req['page'].to_i+1})
    repository.concat(req['results'])
  end
  return repository
end

@products = []
@products = get_all_products

#Products that for some reason won't cooperate
wonky_products = ['Red Hat Enterprise Linux High Performance Networking for RHEL Server - Extended Update Support', 'Red Hat EUCJP Support for RHEL Server - Extended Update Support']


puts_verbose("#{@options[:output_csv_file]}")
if @options[:output_csv_file] 
    begin
        CSV.open(@options[:output_csv_file],'w') do |f|
            f << ["Reposet ID", "Product ID", "Product Name" , "Repo Name", "Basearch", "Releasever", "Repo Label"]
        end
    end
end
if @options[:output_yaml_file] 
    begin
        File.open(@options[:output_yaml_file],'w') do |f|
            yaml = { 'redhat_repositories' => []}
            f << yaml.to_yaml
        end
    end
end

for product in @products
    if wonky_products.include?(product['name'])
        next
    end
    puts "####### #{product['name']} ########"
    enabled_repositories = get_all_enabled_repositories(product['id'])    
    if enabled_repositories.empty?
        next
    end
    enabled_repo_names = []
    enabled_repo_ids = []
    enabled_repositories.each do |repository|
   #     puts_verbose( "repository #{repository['id']},  #{repository['name']},#{repository['basearch']} #{repository['content_type']} ,#{repository['']}")
        enabled_repo_names << repository['name']
        enabled_repo_ids << repository['id']
    end
    puts_verbose("Enabled REPOS:")
    puts_verbose( enabled_repo_names )
    puts_verbose( "----")

    repository_sets = get_all_repository_sets(product['id'])
    repository_sets.each do |repo_set|
        if repo_set['vendor'] != 'Red Hat'
            next
        end
       repo_set_repo_names = []
        repo_set['repositories'].each do |repo_set_repo|
            repo_set_repo_names << repo_set_repo['name']
        end
        repo_set_repo_names.each do |repo_set_repo_name|
            if enabled_repo_names.include?(repo_set_repo_name)
                puts_verbose("REPO SET REPO #{repo_set_repo_name} matches with the product enabled repo name")
                repo_set_repos = get_repository_set_repos(product['id'], repo_set['id'])
                repo_set_repos.each do |repo|
#                    puts "Inspecting #{repo}"
                    if enabled_repo_names.include?(repo['repo_name'])

        #                puts "#{repo_set['id']} #{repo_set['name']}"
         #               puts repo_set
                        puts "-------------------------"
                        puts "Product-ID: #{product['id']} "
                        puts "Repo-Set ID: #{repo_set['id']}"
                        puts "Repo-Set Repo #{repo['name']}"
                        puts "Repo-Set Repo Full Name #{repo['repo_name']}"
                        puts "Repo-Set Label #{repo_set['label']}"
                        puts "Repo-Set Basearch #{repo['substitutions']['basearch']}"
                        puts "Repo-Set Releasever#{repo['substitutions']['releasever']}"
                        puts_verbose "Repository Object:"
                        puts_verbose repo
                        puts_verbose "RepositorySet Object"
                        puts_verbose repo_set
                        puts "-------------------------"
                        repo_line= " #{repo_set['id']}, #{product['id']}, #{repo['substitutions']['basearch']}, #{repo['substitutions']['releasever']} \n"
                        repo_array = [repo_set['id'], product['id'], product['name'], repo['repo_name'], repo['substitutions']['basearch'], repo['substitutions']['releasever'] ]

                        if not @options[:output_csv_file].nil?
                            CSV.open(@options[:output_file],'a') do |f| 
                                f <<  [repo_set['id'], product['id'], product['name'], repo['repo_name'], repo['substitutions']['basearch'], repo['substitutions']['releasever'], repo_set['label'] ]
                            end
                        end
                        if @options[:output_yaml_file]
                             line = {
                                'product'       => product['name'],
                                'repo_name'     => repo['repo_name'],
                                'product_id'    => product['id'].to_i,
                                'reposet_id'    => repo_set['id'].to_i,
                                'repo_label'    => repo_set['label']
                             }
                            if not repo['substitutions']['basearch'].nil?
                                line['basearch'] = repo['substitutions']['basearch']
                            end
                            if not repo['substitutions']['releasever'].nil? 
                                line['releasever'] = repo['substitutions']['releasever']
                            end
                            reposets = YAML.load_file(@options[:output_yaml_file])
                            reposets['redhat_repositories'] << line
                            
                            File.write(@options[:output_yaml_file],reposets.to_yaml)
                        end
                    end
                end
            end
        end
    end
end
#if @options[:output_yaml_file]
#    @products.each do |product|
#        
#        command = "/usr/bin/sed -i '0,/.*#{product['name']}.*/s/.*#{product['name']}.*/\\n # #{product['name']}\\n&/' #{@options[:output_yaml_file]}"
#        puts "#{command}"
#        system(command)
#
#    end
#    
#end
