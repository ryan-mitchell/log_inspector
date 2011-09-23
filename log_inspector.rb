require 'simple_worker'
require 'time'
require 'date'

class LogInspector < SimpleWorker::Base

  attr_accessor :statuses, :config

  merge_gem 'aws-sdk'
  merge_gem 'cloud-logger'
  merge_gem 'pony'

	def run

    AWS.config(@config['aws'])
    @loggly = CloudLogger::Loggly.new(
      :subdomain => @config['loggly']['subdomain'],
      :user => @config['loggly']['user'],
      :pass => @config['loggly']['pass'],
    )
    LogStatus.set_log(@loggly)

    cache_all_statuses

    LogNotification.find(:all).select {|s| s.is_active? }.each do |notification|

      status = @statuses.find(notification.event_id)

      if status.active
        if status.active_for_longer_than notification.begin_after 
          notification.last_notification = Time.now.to_i
          notification.save!
          notification.email_addresses.each do |recipient|
            puts "Notifying " + recipient + " of " + status.status_name
            Pony.mail(
              :to => recipient, 
              :from => 'rubymailer@psship.com', 
              :subject => status.status_name,
              :body => status.status_description,
              :via => :smtp,
              :via_options => {
                :address => 'smtp.gmail.com'
              }
            )
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

  # TODO will simpleworker let us pull this class out into another file? it's getting a little bloated
  class LogStatus < AWS::Record::Base
    set_domain_name "LogStatus"
    string_attr :status_code
    string_attr :matched
    string_attr :status_name
    string_attr :status_description
    string_attr :search_string_begin, :set => true
    string_attr :search_string_end, :set => true
    integer_attr :status_since
    boolean_attr :active

    def self.set_log(log)
      @@log = log
    end

    # TODO can these be combined into one validation? 
    validates_each(:search_string_begin) do |record, attr_name, val|
      if record.extract_wildcards(val).count > 1
        record.errors.add(attr_name, 'may not contain more than one wildcard pattern')
      end   
      if record.extract_wildcards(val).count == 1 and record.extract_wildcards(record.search_string_end).count == 0
        record.errors.add(attr_name, 'may not contain a wildcard pattern in the begin string without a corresponding pattern in the end string')
      end
    end

    validates_each(:search_string_end) do |record, attr_name, val|
      if record.extract_wildcards(val).count > 1
        record.errors.add(attr_name, 'may not contain more than one wildcard pattern')
      end   
      if record.extract_wildcards(val).count == 1 and record.extract_wildcards(record.search_string_begin).count == 0
        record.errors.add(attr_name, 'may not contain a wildcard pattern in the end string without a corresponding pattern in the begin string')
      end
    end

    def active_for_longer_than(lag_time)
      self.active and (Time.now.to_i - self.status_since > lag_time)
    end

    # returns true, false, or nil if the status is unknown 
    def wildcard_status_search

      if wildcard_begin and wildcard_end

        all_starts = @@log.search(wildcard_begin)
        all_ends = @@log.search(wildcard_end)

        if all_starts.empty? and all_ends.empty?
          return nil
        end
      
        all_matches = all_starts | all_ends
        submatches = extract_submatches(all_starts, wildcard_begin) | extract_submatches(all_ends, wildcard_end)

        all_pass = submatches.all? do |sm|

          successes_for_submatch = all_starts.select {|start| start.text.include?  wildcard_begin.sub('[*]', sm)}.sort {|a,b| b.timestamp <=> a.timestamp }
          failures_for_submatch = all_ends.select {|ending| ending.text == wildcard_end.sub('[*]', sm)}.sort {|a,b| b.timestamp <=> a.timestamp }               

          #optimize for the most likely case - no failures
          if failures_for_submatch.empty? and not successes_for_submatch.empty?
            passing = true 
          elsif successes_for_submatch.empty? and not failures_for_submatch.empty?
            passing = false
          else
            passing = successes_for_submatch.first.timestamp > failures_for_submatch.first.timestamp 
          end

          row = LogStatus.where("matched = '#{sm}'").first
          unless row
            new_attributes = attributes.clone.merge(:status_since => Time.now.to_i, :matched => sm) 
            new_attributes.delete(:id)
            row = LogStatus.new(new_attributes)
            row.save!
          end
      
          if passing
            row.enable
          else
            row.disable
          end
           
          passing
        end
      else
        true # no wildcards to check, so the check passes (in that there can be no failures) 
      end
    end

    def extract_wildcards(patterns)
      patterns.select {|p| p.include? '[*]' }
    end

    def enable
      unless active?
        self.status_since = Time.now.to_i
        self.active = true
        save!
      end
    end

    def disable
      if active? or active.nil?
        self.status_since = Time.now.to_i
        self.active = false
        save!
      end
    end

    def enabled_times
      get_event_times(search_string_begin)
    end

    def disabled_times
      get_event_times(search_string_end)
    end
    
    private

    # returns the wildcard pattern or nil
    def wildcard_begin
      extract_wildcards(search_string_begin).first
    end

    # returns the wildcard pattern or nil
    def wildcard_end
      extract_wildcards(search_string_end).first
    end 

    # returns all non-wildcard starting patterns
    def begin_patterns
      search_string_begin.select { |ssb| not ssb.include? '[*]' }
    end

    # returns all non-wildcard ending patterns
    def end_patterns
      search_string_end.select { |sse| not sse.include? '[*]' }
    end

    def get_wildcard_patterns(search_string_array)
      search_string_array.select do |search_string|
        search_string.include? '[*]'
      end     
    end

    # Turn the convenience notation used in the UI to the correct regular expression for matching
    def fix_regexp(original_regexp)
      # If the wildcard is the last word in the string, we have to assume that it's going
      # to be followed by a non-word character or the end of the string - otherwise, we trust the pattern to
      # tell us what comes after it 
      fixed_matcher = original_regexp.end_with?('[*]') ? '(.+?)\b' : '(.+?)' 
      original_regexp.sub('[*]', fixed_matcher) 
    end

    def extract_submatches(matches, original_pattern)
      matches.map do |m|
        fixed_regexp = fix_regexp(original_pattern)
        m.text.scan(Regexp.new(fixed_regexp))[0][0] # assume there's only one match
      end
    end

    def get_event_times(search_string_array)
      search_string_array.collect do |search_string|
        response = @@log.search(search_string)
        if response.kind_of?(Array) and response.count > 0
          response.first.timestamp.to_time.to_i
        else
          0 # timestamp of 0 is the same as "this has never happened" 
        end
      end
    end
  end

  private
  def cache_all_statuses
    @statuses = LogStatus.find(:all)
    @statuses.select {|s| s.matched.nil? }.each do |status|
    
      wildcard_check_passes = status.wildcard_status_search

      # if this is a false (not nil) result, no point in continuing - disable the status and skip this iteration
      if not wildcard_check_passes and not wildcard_check_passes.nil?
        status.disable
        next
      end  

      # if the result is true and there are no more patterns to check, again, no reason to continue - 
      # enable the status and skip the iteration
      if wildcard_check_passes and status.search_string_begin.empty? and status.search_string_end.empty?
        status.enable
        next
      else # if, after removing wildcard patterns, we still have patterns to check, continue 
        if status.enabled_times.max != 0 or status.disabled_times.max != 0
          if status.enabled_times.max > status.disabled_times.max
            status.enable
          else
            status.disable
          end
        end
      end
    end
  end
end


