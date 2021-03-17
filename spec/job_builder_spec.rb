require 'spec_helper'

RSpec.describe Nomade::JobBuilder do
  it "should build a job object" do
    http = Nomade::Http.new(nomad_endpoint)
    job_builder = Nomade::JobBuilder.new(http)
    job = job_builder.build("spec/jobfiles/whoami.hcl.erb", "billetto/billetto-rails:4.2.24", {
      datacenter: "eu-test-1",
      dns: "172.17.0.1",
      environment_variables: {
        "DEPLOY_TIME"  => Time.now.utc.to_s,
      }
    })

    expect(job.class).to eq Nomade::Job
    expect(job.job_name).to eq "whoami-web"
    expect(job.job_type).to eq "service"
    expect(job.image_name_and_version).to eq "billetto/billetto-rails:4.2.24"
    expect(job.image_name).to eq "billetto/billetto-rails"
    expect(job.image_version).to eq "4.2.24"
  end
end
