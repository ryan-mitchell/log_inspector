require 'simple_worker'
#require 'ruby_loggly'
require 'time'
require 'date'
#require 'pony'

class LogInspector < SimpleWorker::Base

  attr_accessor :statuses, :config

  merge_gem 'aws-sdk'
  merge_gem 'ruby_loggly'
  merge_gem 'pony'

	def run

    AWS.config(@config['aws'])
    @loggly = Loggly.new(
      :subdomain => @config['loggly']['subdomain'],
      :user => @config['loggly']['user'],
      :pass => @config['loggly']['pass'],
    )

    cache_all_statuses

    LogNotification.find(:all).select {|s| s.is_active? }.each do |notification|

      status = @statuses.find(notification.event_id)

      if status.active
        if status.active_for_longer_than notification.begin_after 
          notification.last_notification = Time.now.to_i
          notification.save!
          notification.email_addresses.each do |recipient|
            puts "Notifying " + recipient + " of " + status.status_name
=begin
            Pony.mail(
              :to => recipient, 
              :from => 'rubymailer@psship.com', 
              :subject => status.status_name,
              :body => status.status_description,
              :via => :smtp,
              :via_options => {
                :address => 'smtp.psship.com'
              }
            )
=end
          end
        end
      else
        # if the status is not active, reset the last_notification time so we'll get an email
        # immediately if the status becomes active again right away
        notification.last_notification = 0
        notification.save!
      end
    end
  end

  class LogNotification < AWS::Record::Base
    set_domain_name "LogNotification"
    string_attr :email_addresses, :set => true
    string_attr :event_id
    integer_attr :how_often
    integer_attr :last_notification
    integer_attr :begin_after

    def is_active?
       Time.now.to_i - self['last_notification'] > self['how_often']
    end
  end

  class LogStatus < AWS::Record::Base
    set_domain_name "LogStatus"
    string_attr :status_name
    string_attr :status_description
    string_attr :search_string_begin, :set => true
    string_attr :search_string_end, :set => true
    integer_attr :status_since
    boolean_attr :active

    def active_for_longer_than(lag_time)
      self.active and (Time.now.to_i - self.status_since > lag_time)
    end
  end

  private
  def cache_all_statuses
    @statuses = LogStatus.find(:all)
    @statuses.each do |status|

      # A status may only contain ONE wildcard search string - otherwise there'd be
      # ambiguity as far as which success strings correspond with which failure strings.
      # If there is a wildcard search string in the begin strings but not in the end
      # strings (or vice versa) the wildcard will be treated as regular literal text.
      wildcard_starts = get_wildcard_patterns(status.search_string_begin)
      wildcard_endings = get_wildcard_patterns(status.search_string_end)

      if wildcard_starts.count > 1 or wildcard_endings.count > 1
        raise "A status may not contain multiple wildcard search strings in either the beginning or ending string."
      end
    
      unless wildcard_starts.empty? or wildcard_endings.empty?

        wildcard_start = wildcard_starts.first
        wildcard_end = wildcard_endings.first
        all_starts = @loggly.search(wildcard_start)['data']
        all_ends = @loggly.search(wildcard_end)['data']

        if all_starts.empty?
          disable(status)
          next
        end
    
        all_starts.each do |entry|
          # convert convenience notation into actual regex
          real_regex = wildcard_start.end_with?('[*]') ? '(.*?) ' : '(.*?)'
          search_string = wildcard_start.sub('[*]', real_regex) # TODO fix 
          matched_text = entry['text'].scan(Regexp.new(search_string))[0][0] # assume there's only one match
          matching_end_string = wildcard_end.sub('[*]', matched_text)
           
          # the most recent time this status succeeded
          selected = all_ends.select do |end_entry|
            (DateTime.parse(end_entry['timestamp']) > DateTime.parse(entry['timestamp'])) and 
            end_entry['text'].include? matching_end_string
          end

          if selected.empty?
            enable(status)
          else
            disable(status)
            next # no need to check the non-wildcard patterns if we've already failed
          end
        end     
      
        # remove the wildcard patterns from the pattern array so we don't try to match them
        # like standard patterns
        status.search_string_begin.delete(wildcard_start)
        status.search_string_end.delete(wildcard_end)
      end
   
      # if, after removing wildcard patterns, our array is empty, don't bother searching the logs 
      if not (status.search_string_begin.empty? and status.search_string_end.empty?)
        enabled_times = get_event_times(status.search_string_begin)
        disabled_times = get_event_times(status.search_string_end)

        if enabled_times.max > disabled_times.max
          enable(status)
        else
          disable(status)
        end
      end
    end
  end

  def enable(status)
    unless status.active?
      status.status_since = Time.now.to_i
      status.active = true
      status.save!
    end
  end

  def disable(status)
    if status.active?
      status.status_since = Time.now.to_i
      status.active = false
      status.save!
    end
  end

  def get_wildcard_patterns(search_string_array)
    search_string_array.select do |search_string|
      search_string.include? '[*]'
    end     
  end

  def get_event_times(search_string_array)
    search_string_array.collect do |search_string|
      response = @loggly.search(search_string)
      if response.kind_of?(Hash) and response['data'].count > 0
        DateTime.parse response['data'].first['timestamp']
      else
        DateTime.new(0) # timestamp of 0 is the same as "this has never happened" 
      end
    end
  end
end


