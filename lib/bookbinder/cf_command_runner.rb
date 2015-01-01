require 'open3'

class CfCommandRunner
  attr_reader :creds

  def initialize(logger, cf_credentials, trace_file)
    @logger = logger
    @creds = cf_credentials
    @trace_file = trace_file
  end

  def login
    username = creds.username
    password = creds.password
    api_endpoint = creds.api_endpoint
    organization = creds.organization
    space = creds.space
    creds_string = (username && password) ? "-u '#{username}' -p '#{password}'" : ''

    success = Kernel.system("#{cf_binary_path} login #{creds_string} -a '#{api_endpoint}' -o '#{organization}' -s '#{space}'")
    raise "Could not log in to #{creds.api_endpoint}" unless success
  end

  def apps
    existing_hosts = routes.reject { |domain, host| new_route?(domain, host) }
    if existing_hosts.any?
      existing_hosts.map { |domain, host| apps_for_host(domain, host) }
    else
      raise "cannot find currently deployed app."
    end
  end

  def apps_for_host(domain, host)
    route = routes_for(domain, host).first
    if route
      apps_with_route = route.rstrip.match(/#{Regexp.escape(domain)}\s+(.+)$/)
      if apps_with_route.nil?
        raise "no apps found for host #{host}"
      else
        apps_with_route[1].split(',').map { |app| app.strip }
      end
    else
      raise "no routes found for route #{host}.#{domain}"
    end
  end

  def start(deploy_target_app)
    # Theoretically we shouldn't need this (and corresponding "stop" below), but we've seen CF pull files from both
    # green and blue when a DNS redirect points to HOST.cfapps.io
    # Also, shutting down the unused app saves $$
    Kernel.system("#{cf_binary_path} start #{deploy_target_app} ")
  end

  def push(deploy_target_app)
    # Currently --no-routes is used to blow away all existing routes from a newly deployed app.
    # The routes will then be recreated from the creds repo.
    success = Kernel.system(environment_variables, "#{cf_binary_path} push #{deploy_target_app} --no-route -m 256M -i 3")
    raise "Could not deploy app to #{deploy_target_app}" unless success
  end

  def environment_variables
    {'CF_TRACE' => @trace_file}
  end

  def unmap_routes(app)
    routes.each do |domain, host|
      unmap_route(app, domain, host)
    end
  end

  def map_routes(app)
    succeeded = []

    routes.each do |domain, name|
      begin
        map_route(app, domain, name)
        succeeded << [app, domain, name]
      rescue
        succeeded.each { |app, domain, host| unmap_route(app, domain, host) }
        raise
      end
    end
  end

  def takedown_old_target_app(app)
    # Routers flush every 10 seconds (but not guaranteed), so wait a bit longer than that.
    @logger.log "waiting 15 seconds for routes to remap...\n\n"
    (1..15).to_a.reverse.each do |seconds|
      @logger.log_print "\r\r#{seconds}...    "
      Kernel.sleep 1
    end
    stop(app)
    unmap_routes(app)
  end

  private

  def routes
    creds.routes.reduce([]) do |all_routes, domain_apps|
      domain, apps = domain_apps
      all_routes + apps.map { |app| [domain, app] }
    end
  end

  def stop(app)
    success = Kernel.system("#{cf_binary_path} stop #{app}")
    raise "Failed to stop application #{app}" unless success
  end

  def map_route(deploy_target_app, domain, host)
    map_route_command = "#{cf_binary_path} map-route #{deploy_target_app} #{domain}"
    map_route_command += " -n #{host}" unless host.empty?

    success = Kernel.system(map_route_command)
    raise "Deployed app to #{deploy_target_app} but failed to map hostname #{host}.#{domain} to it." unless success
  end

  def unmap_route(deploy_target_app, domain, host)
    unmap_route_command = "#{cf_binary_path} unmap-route #{deploy_target_app} #{domain}"
    unmap_route_command += " -n #{host}" unless host.empty?

    success = Kernel.system(unmap_route_command)
    raise "Failed to unmap route #{host} on #{deploy_target_app}." unless success
  end

  def cf_binary_path
    @cf_binary_path ||= `which cf`.chomp!
    raise "CF CLI could not be found in your PATH. Please make sure cf cli is in your PATH." if @cf_binary_path.nil?
    @cf_binary_path
  end

  def cf_routes_output
    output, status = Open3.capture2("CF_COLOR=false #{cf_binary_path} routes")
    raise 'failure executing cf routes' unless status.success?
    output
  end

  def routes_for(domain, host)
    cf_routes_output.lines.grep(/^#{Regexp.escape(host)}\s+#{Regexp.escape(domain)}\s+/)
  end

  def new_route?(domain, host)
    routes_for(domain, host).empty?
  end
end
