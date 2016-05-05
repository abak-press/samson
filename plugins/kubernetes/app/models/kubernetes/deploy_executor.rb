# executes a deploy and writes log to job output
# finishes when cluster is "Ready"
module Kubernetes
  class DeployExecutor
    STABLE_TICKS = 20
    RESTARTED = "Restarted"

    ReleaseStatus = Struct.new(:live, :details, :role, :group)

    def initialize(output, job:)
      @output = output
      @job = job
    end

    def pid
      "Kubernetes-deploy-#{object_id}"
    end

    def stop!(_signal)
      @stopped = true
    end

    def execute!(*_commands)
      build = find_or_create_build
      return false if stopped?
      release = create_release(build)
      ensure_service(release)
      create_deploys(release)
      success = wait_for_deploys_to_finish(release)
      show_failure_cause(release) unless success
      success
    end

    private

    def wait_for_deploys_to_finish(release)
      loop do
        return false if stopped?

        statuses = pod_statuses(release)

        if @testing_for_stability
          if statuses.all?(&:live)
            @testing_for_stability += 1
            @output.puts "Stable #{@testing_for_stability}/#{STABLE_TICKS}"
            if STABLE_TICKS == @testing_for_stability
              @output.puts "SUCCESS"
              return true
            end
          else
            print_statuses(statuses)
            unstable!
            return false
          end
        else
          print_statuses(statuses)
          if statuses.all?(&:live)
            @output.puts "READY, starting stability test"
            @testing_for_stability = 0
          elsif statuses.map(&:details).include?(RESTARTED)
            unstable!
            return false
          end
        end

        sleep 2
      end
    end

    def pod_statuses(release)
      pods = release.clients.flat_map { |client, query| fetch_pods(client, query) }
      release.release_docs.map { |release_doc| release_status(pods, release_doc) }
    end

    def fetch_pods(client, query)
      client.get_pods(query).map! { |p| Kubernetes::Api::Pod.new(p) }
    end

    def show_failure_cause(release)
      bad_pods = release.clients.flat_map do |client, query, deploy_group|
        bad_pods = fetch_pods(client, query).select { |p| p.restarted? || !p.live? }
        bad_pods.map { |p| [p, client, deploy_group] }
      end

      bad_pods.each do |pod, client, deploy_group|
        namespace = deploy_group.kubernetes_namespace
        @output.puts "\n#{deploy_group.name} pod #{pod.name}:"

        # events - not enough cpu/ram available
        @output.puts "EVENTS:"
        events = client.get_events(namespace: namespace, field_selector: "involvedObject.name=#{pod.name}")
        events.uniq! { |e| e.message.split("\n").sort }
        events.each { |e| @output.puts "#{e.reason}: #{e.message}" }

        # logs - container fails to boot
        @output.puts "\nLOGS:"
        @output.puts client.get_pod_log(pod.name, namespace, previous: pod.restarted?)
      end
    end

    def unstable!
      @output.puts "UNSTABLE - service is restarting"
    end

    def stopped?
      if @stopped
        @output.puts "STOPPED"
        true
      end
    end

    def release_status(pods, release_doc)
      group = release_doc.deploy_group
      role = release_doc.kubernetes_role

      pod = pods.detect { |pod| pod.role_id == role.id && pod.deploy_group_id == group.id }

      live, details = if pod
        if pod.live?
          if pod.restarted?
            [false, RESTARTED]
          else
            [true, "Live"]
          end
        else
          [false, "Waiting (#{pod.phase}, not Ready)"]
        end
      else
        [false, "Missing"]
      end

      ReleaseStatus.new(live, details, role.name, group.name)
    end

    def print_statuses(statuses)
      statuses.group_by(&:group).each do |group, statuses|
        @output.puts "#{group}:"
        statuses.each do |status|
          @output.puts "  #{status.role}: #{status.details}"
        end
      end
    end

    def find_or_create_build
      build = Build.find_by_git_sha(@job.commit) || create_build
      wait_for_build(build)
      ensure_build_is_successful(build) unless @stopped
      build
    end

    def wait_for_build(build)
      if !build.docker_repo_digest && build.docker_build_job.try(:running?)
        @output.puts("Waiting for Build #{build.url} to finish.")
        loop do
          break if @stopped
          sleep 2
          break if build.docker_build_job(:reload).finished?
        end
      end
      build.reload
    end

    def create_build
      @output.puts("Creating Build for #{@job.commit}.")
      build = Build.create!(
        git_ref: @job.commit,
        creator: @job.user,
        project: @job.project,
        label: "Automated build triggered via Deploy ##{@job.deploy.id}"
      )
      DockerBuilderService.new(build).run!(push: true)
      build
    end

    def ensure_build_is_successful(build)
      if build.docker_repo_digest
        @output.puts("Build #{build.url} is looking good!")
      elsif build_job = build.docker_build_job
        raise Samson::Hooks::UserError, "Build #{build.url} is #{build_job.status}, rerun it manually."
      else
        raise Samson::Hooks::UserError, "Build #{build.url} was created but never ran, run it manually."
      end
    end

    # create a realese, storing all the configuration
    def create_release(build)
      # build config for every cluster and role we want to deploy to
      group_config = @job.deploy.stage.deploy_groups.map do |group|
        roles = Kubernetes::Role.where(project_id: @job.project_id).map do |role|
          {id: role.id, replicas: role.replicas} # TODO make replicas configureable
        end
        {id: group.id, roles: roles}
      end

      release = Kubernetes::Release.create_release(deploy_groups: group_config, build_id: build.id, user: @job.user, project: @job.project)
      unless release.persisted?
        raise Samson::Hooks::UserError, "Failed to create release: #{release.errors.full_messages.inspect}"
      end
      @output.puts("Created release #{release.id}\nConfig: #{group_config.inspect}")
      release
    end

    # Create deploys
    def create_deploys(release)
      release.release_docs.each do |release_doc|
        @output.puts "Creating deploy for #{release_doc.deploy_group.name} role #{release_doc.kubernetes_role.name}"
        release_doc.deploy_to_kubernetes
      end
    end

    # Create the service or report it's status
    def ensure_service(release)
      release.release_docs.each do |release_doc|
        role = release_doc.kubernetes_role
        service = release_doc.service
        status = release_doc.ensure_service
        @output.puts "#{status} for role #{role.name} / service #{service ? service.name : "none"}"
      end
    end
  end
end
