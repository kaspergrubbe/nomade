require "net/https"
require "json"

module Nomade
  class Http
    def initialize(nomad_endpoint)
      @nomad_endpoint = nomad_endpoint
    end

    def job_index_request(search_prefix = nil)
      search_prefix = if search_prefix
        "?prefix=#{search_prefix}"
      else
        ""
      end
      uri = URI("#{@nomad_endpoint}/v1/jobs#{search_prefix}")

      http = Net::HTTP.new(uri.host, uri.port)
      if @nomad_endpoint.include?("https://")
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end

      req = Net::HTTP::Get.new(uri)
      req.add_field "Content-Type", "application/json"

      res = http.request(req)

      raise if res.code != "200"
      raise if res.content_type != "application/json"

      return JSON.parse(res.body)
    rescue StandardError => e
      Nomade.logger.fatal "HTTP Request failed (#{e.message})"
      raise
    end

    def evaluation_request(evaluation_id)
      uri = URI("#{@nomad_endpoint}/v1/evaluation/#{evaluation_id}")

      http = Net::HTTP.new(uri.host, uri.port)
      if @nomad_endpoint.include?("https://")
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end

      req = Net::HTTP::Get.new(uri)
      req.add_field "Content-Type", "application/json"

      res = http.request(req)

      raise if res.code != "200"
      raise if res.content_type != "application/json"

      return JSON.parse(res.body)
    rescue StandardError => e
      Nomade.logger.fatal "HTTP Request failed (#{e.message})"
      raise
    end

    def allocations_from_evaluation_request(evaluation_id)
      uri = URI("#{@nomad_endpoint}/v1/evaluation/#{evaluation_id}/allocations")

      http = Net::HTTP.new(uri.host, uri.port)
      if @nomad_endpoint.include?("https://")
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end

      req = Net::HTTP::Get.new(uri)
      req.add_field "Content-Type", "application/json"

      res = http.request(req)

      raise if res.code != "200"
      raise if res.content_type != "application/json"

      return JSON.parse(res.body)
    rescue StandardError => e
      Nomade.logger.fatal "HTTP Request failed (#{e.message})"
      raise
    end

    def deployment_request(deployment_id)
      uri = URI("#{@nomad_endpoint}/v1/deployment/#{deployment_id}")

      http = Net::HTTP.new(uri.host, uri.port)
      if @nomad_endpoint.include?("https://")
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end

      req = Net::HTTP::Get.new(uri)
      req.add_field "Content-Type", "application/json"

      res = http.request(req)

      raise if res.code != "200"
      raise if res.content_type != "application/json"

      return JSON.parse(res.body)
    rescue StandardError => e
      Nomade.logger.fatal "HTTP Request failed (#{e.message})"
      raise
    end

    def check_if_job_exists?(nomad_job)
      jobs = job_index_request(nomad_job.job_name)
      jobs.map{|job| job["ID"]}.include?(nomad_job.job_name)
    end

    def create_job(nomad_job)
      uri = URI("#{@nomad_endpoint}/v1/jobs")

      http = Net::HTTP.new(uri.host, uri.port)
      if @nomad_endpoint.include?("https://")
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end

      req = Net::HTTP::Post.new(uri)
      req.add_field "Content-Type", "application/json"
      req.body = JSON.generate({"Job" => nomad_job.configuration(:hash)})

      res = http.request(req)

      raise if res.code != "200"
      raise if res.content_type != "application/json"

      return JSON.parse(res.body)["EvalID"]
    rescue StandardError => e
      Nomade.logger.fatal "HTTP Request failed (#{e.message})"
      raise
    end

    def update_job(nomad_job)
      uri = URI("#{@nomad_endpoint}/v1/job/#{nomad_job.job_name}")

      http = Net::HTTP.new(uri.host, uri.port)
      if @nomad_endpoint.include?("https://")
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end

      req = Net::HTTP::Post.new(uri)
      req.add_field "Content-Type", "application/json"
      req.body = JSON.generate({"Job" => nomad_job.configuration(:hash)})

      res = http.request(req)

      raise if res.code != "200"
      raise if res.content_type != "application/json"

      return JSON.parse(res.body)["EvalID"]
    rescue StandardError => e
      Nomade.logger.fatal "HTTP Request failed (#{e.message})"
      raise
    end

    def stop_job(nomad_job, purge = false)
      uri = if purge
        URI("#{@nomad_endpoint}/v1/job/#{nomad_job.job_name}?purge=true")
      else
        URI("#{@nomad_endpoint}/v1/job/#{nomad_job.job_name}")
      end

      http = Net::HTTP.new(uri.host, uri.port)
      if @nomad_endpoint.include?("https://")
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end

      req = Net::HTTP::Delete.new(uri)
      req.add_field "Content-Type", "application/json"

      res = http.request(req)
      raise if res.code != "200"
      raise if res.content_type != "application/json"

      return JSON.parse(res.body)["EvalID"]
    rescue StandardError => e
      Nomade.logger.fatal "HTTP Request failed (#{e.message})"
      raise
    end

    def promote_deployment(deployment_id)
      uri = URI("#{@nomad_endpoint}/v1/deployment/promote/#{deployment_id}")

      http = Net::HTTP.new(uri.host, uri.port)
      if @nomad_endpoint.include?("https://")
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end

      req = Net::HTTP::Post.new(uri)
      req.add_field "Content-Type", "application/json"
      req.body = {
        "DeploymentID" => deployment_id,
        "All" => true,
      }.to_json

      res = http.request(req)
      raise if res.code != "200"
      raise if res.content_type != "application/json"

      return true
    rescue StandardError => e
      Nomade.logger.fatal "HTTP Request failed (#{e.message})"
      raise
    end

    def fail_deployment(deployment_id)
      uri = URI("#{@nomad_endpoint}/v1/deployment/fail/#{deployment_id}")

      http = Net::HTTP.new(uri.host, uri.port)
      if @nomad_endpoint.include?("https://")
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end

      req = Net::HTTP::Post.new(uri)
      req.add_field "Content-Type", "application/json"

      res = http.request(req)
      raise if res.code != "200"
      raise if res.content_type != "application/json"

      return true
    rescue StandardError => e
      Nomade.logger.fatal "HTTP Request failed (#{e.message})"
      raise
    end

    def get_allocation_logs(allocation_id, task_name, logtype)
      uri = URI("#{@nomad_endpoint}/v1/client/fs/logs/#{allocation_id}?task=#{task_name}&type=#{logtype}&plain=true&origin=end")

      http = Net::HTTP.new(uri.host, uri.port)
      if @nomad_endpoint.include?("https://")
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end

      req = Net::HTTP::Get.new(uri)
      res = http.request(req)
      raise if res.code != "200"

      return res.body.gsub(/\e\[\d+m/, '')
    rescue StandardError => e
      Nomade.logger.fatal "HTTP Request failed (#{e.message})"
      raise
    end

    def capacity_plan_job(nomad_job)
      plan_output = plan_job2(nomad_job)

      if plan_output["FailedTGAllocs"]
        raise Nomade::FailedTaskGroupPlan.new("Failed to plan groups: #{plan_output["FailedTGAllocs"].keys.join(",")}")
      end

      true
    rescue Nomade::FailedTaskGroupPlan => e
      raise
    rescue StandardError => e
      Nomade.logger.fatal "HTTP Request failed (#{e.message})"
      raise
    end

    def convert_hcl_to_json(job_hcl)
      uri = URI("#{@nomad_endpoint}/v1/jobs/parse")

      http = Net::HTTP.new(uri.host, uri.port)
      if @nomad_endpoint.include?("https://")
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end

      req = Net::HTTP::Post.new(uri)
      req.add_field "Content-Type", "application/json"

      req.body = JSON.generate({
        "JobHCL": job_hcl,
        "Canonicalize": false,
      })

      res = http.request(req)
      raise if res.code != "200"
      raise if res.content_type != "application/json"

      res.body
    rescue StandardError => e
      Nomade.logger.fatal "HTTP Request failed (#{e.message})"
      raise
    end

    def plan_job(nomad_job)
      uri = URI("#{@nomad_endpoint}/v1/job/#{nomad_job.job_name}/plan")

      http = Net::HTTP.new(uri.host, uri.port)
      if @nomad_endpoint.include?("https://")
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end

      req = Net::HTTP::Post.new(uri)
      req.add_field "Content-Type", "application/json"
      req.body = JSON.generate({"Job" => nomad_job.configuration(:hash)})

      res = http.request(req)
      raise if res.code != "200"
      raise if res.content_type != "application/json"

      JSON.parse(res.body)
    rescue StandardError => e
      Nomade.logger.fatal "HTTP Request failed (#{e.message})"
      raise
    end

  end
end
