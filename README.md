# Ruby-wrapper for talking with Hashicorp Nomad

Nomad from https://www.nomadproject.io/

## Example:

```ruby
require 'bundler/inline'
gemfile do
  source 'https://rubygems.org'
  gem "nomade"
end

environment = {
  "RAILS_ENV"                => "production",
  "RAILS_SERVE_STATIC_FILES" => "1",
  "RAILS_LOG_TO_STDOUT"      => "1",
  "FORCE_SSL"                => "1",
  "DATABASE_NAME"            => "clusterapp_production",
  "DATABASE_USERNAME"        => "kasper",
  "DATABASE_PASSWORD"        => "hunter2",
  "DATABASE_HOSTNAME"        => "db.kaspergrubbe.com",
  "DATABASE_PORT"            => "5432",
}

image_name = "kaspergrubbe/clusterapp:0.0.11"
nomad_job_migration = Nomade::Job.new('templates/clusterapp-batch.nomad.hcl.erb', image_name, environment)
nomad_job_web = Nomade::Job.new('templates/clusterapp.nomad.hcl.erb', image_name, environment)

Nomade::Deployer.new("https://kg.nomadserver.com", nomad_job_migration).deploy!
Nomade::Deployer.new("https://kg.nomadserver.com", nomad_job_web).deploy!
```
