require 'simple_worker'
require_relative 'log_inspector'

conf = YAML.load_file('config.yml')

# Put in a config block containing your SimpleWorker access keys
SimpleWorker.configure do |config|
    config.access_key = conf['simple_worker']['access_key'] 
    config.secret_key = conf['simple_worker']['secret_key'] 
end

worker = LogInspector.new
worker.config = conf
worker.schedule(:run_every => 300, :start_at => Time.now)
