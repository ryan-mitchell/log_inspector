require '../log_inspector'
require 'active_support/core_ext'

describe LogInspector do

  before(:each) do
    Loggly.any_instance.stub(:search) do |query|
      {'data' => @mock_log.select {|log_entry| Regexp.new(query.sub('[*]', '.*?')) =~ log_entry['text'] } }
    end
    @log_inspector = LogInspector.new
    @log_inspector.config = YAML.load_file('../config.yml')
    LogInspector::LogNotification.stub(:find).and_return([])
  end

  describe "for standard search strings" do
    before(:each) do
      # using a factory for this would be nicer
      @test_status = LogInspector::LogStatus.new
      @test_status.stub(:search_string_begin).and_return ['Test:success']
      @test_status.stub(:search_string_end).and_return ['Test:failure']
      @test_status.stub(:save!)
      LogInspector::LogStatus.should_receive(:find).and_return([@test_status])
    end

    describe "when the log has no matching results" do

      before(:each) do
        @mock_log = [
          {'timestamp' => 5.minutes.ago.to_s, 'text' => 'Not a matching log event' }
        ]
      end

      it "should leave an up record in an up state" do
        @test_status.active = true
        @log_inspector.run
        @test_status.active.should == true
      end

      it "should leave a down record in a down state" do
        @test_status.active = false
        @log_inspector.run
        @test_status.active.should == false
      end
    end

    describe "when the log finds that the most recent event is an up event" do
   
      before(:each) do
        @mock_log = [
          {'timestamp' => 5.minutes.ago.to_s, 'text' => @test_status.search_string_begin.first },
          {'timestamp' => 10.minutes.ago.to_s, 'text' => @test_status.search_string_end.first }
        ]
      end 

      it "sets the SimpleDb status to up if it was previously down" do
        @test_status.active = false
        @log_inspector.run
        @test_status.active.should == true
      end

      it "sets the SimpleDb status to up if it has never been set before" do
        @test_status.active = nil
        @log_inspector.run
        @test_status.active.should == true
      end

      it "does not change the SimpleDb status if it was already up" do
        @test_status.active = true
        @test_status.should_not_receive(:active=)
        @test_status.should_not_receive(:save!)
        @log_inspector.run
      end
    end

    describe "when the log finds that the most recent event is a down event" do

      before(:each) do
        @mock_log = [
          {'timestamp' => 5.minutes.ago.to_s, 'text' => @test_status.search_string_end.first },
          {'timestamp' => 10.minutes.ago.to_s, 'text' => @test_status.search_string_begin.first }
        ]
      end 

      it "sets the SimpleDb status to down if it was previously up" do
        @test_status.active = true
        @log_inspector.run
        @test_status.active.should == false
      end

      it "sets the SimpleDb status to down if it has never been set before" do
        @test_status.active = nil
        @log_inspector.run
        @test_status.active.should == false
      end

      it "does not change the SimpleDb status if it was already down" do
        @test_status.active = false
        @test_status.should_not_receive(:active=)
        @test_status.should_not_receive(:save!)
        @log_inspector.run
      end
    end
  end

  describe "when wildcard patterns are used" do

    before(:each) do
      @test_status = LogInspector::LogStatus.new
      @test_status.stub(:search_string_begin).and_return ['Test for [*]:success']
      @test_status.stub(:search_string_end).and_return ['Test for [*]:failure']
      @client_status = LogInspector::LogStatus.new
      @client_status.stub(:search_string_begin).and_return ['Test for [*]:success']
      @client_status.stub(:search_string_end).and_return ['Test for [*]:failure']
      @client_status.stub(:matched).and_return "Client1"
      LogInspector::LogStatus.any_instance.stub(:save!)
      LogInspector::LogStatus.should_receive(:find).and_return([@test_status, @client_status])
      LogInspector::LogStatus.should_receive(:where).any_number_of_times.and_return {|query| query == "matched = 'Client1'" ? [@client_status] : [] }
    end 

    it "creates additional status rows for each new match of the wildcard pattern" do
      @mock_log = [
        { 'timestamp' => 5.minutes.ago.to_s, 'text' => 'Test for Client1:success' },
        { 'timestamp' => 10.minutes.ago.to_s, 'text' => 'Test for Client2:success' }     
      ]
      @fake_status = LogInspector::LogStatus.new
      LogInspector::LogStatus.should_receive(:new).once.and_return(@fake_status) # 1 new status should be created, the other one already exists
      @test_status.should_receive(:save!)
      @log_inspector.run
    end

    it "correctly compares the most recent success to the most recent failure" do
      @mock_log = [
        { 'timestamp' => 5.minutes.ago.to_s, 'text' => 'Test for Client1:success' },
        { 'timestamp' => 7.minutes.ago.to_s, 'text' => 'Test for Client1:failure' },
        { 'timestamp' => 10.minutes.ago.to_s, 'text' => 'Test for Client1:success' }     
      ]
      @test_status.active = false
      @test_status.should_receive(:save!)
      @log_inspector.run
      @test_status.active.should == true
    end

    it "updates an existing row for each match of the wildcard pattern", :failing => true do
      @mock_log = [
        { 'timestamp' => 5.minutes.ago.to_s, 'text' => 'Test for Client1:success' },
        { 'timestamp' => 10.minutes.ago.to_s, 'text' => 'Test for Client2:success' }     
      ]
      @client_status.should_receive(:save!)
      @log_inspector.run
    end

    it "sets status to up when there are no down events in the log" do
      @mock_log = [
        { 'timestamp' => 5.minutes.ago.to_s, 'text' => 'Test for Client1:success' },
        { 'timestamp' => 10.minutes.ago.to_s, 'text' => 'Test for Client2:success' }     
      ]
      @test_status.active = false
      @test_status.should_receive(:save!)
      @log_inspector.run
      @test_status.active.should == true
    end

    it "works correctly when there is additional text in the log entry" do
      @mock_log = [
        { 'timestamp' => 5.minutes.ago.to_s, 'text' => 'Test for Client1:success and more text' },
        { 'timestamp' => 10.minutes.ago.to_s, 'text' => 'Test for Client2:success and more text' }     
      ]
      @test_status.active = false
      @test_status.should_receive(:save!)
      @log_inspector.run
      @test_status.active.should == true
    end

    it "works correctly when the wildcard ends the pattern" do
      @test_status.stub(:search_string_begin).and_return ['Test for success:[*]']
      @test_status.stub(:search_string_end).and_return ['Test for failure:[*]']
      @mock_log = [
        { 'timestamp' => 5.minutes.ago.to_s, 'text' => 'Test for success:Client1' },
        { 'timestamp' => 10.minutes.ago.to_s, 'text' => 'Test for success:Client2' }     
      ]
      @test_status.active = false
      @test_status.should_receive(:save!)
      @log_inspector.run
      @test_status.active.should == true
    end

    it "sets status to up when there is one client which has a most recent up event" do
      @mock_log = [
        { 'timestamp' => 5.minutes.ago.to_s, 'text' => 'Test for Client1:success' },
        { 'timestamp' => 10.minutes.ago.to_s, 'text' => 'Test for Client1:failure' }     
      ]
      @test_status.active = false
      @test_status.should_receive(:save!)
      @log_inspector.run
      @test_status.active.should == true
    end

    it "sets status to down when the are no up events in the log" do
      @mock_log = [
        { 'timestamp' => 5.minutes.ago.to_s, 'text' => 'Test for Client1:failure' },
        { 'timestamp' => 10.minutes.ago.to_s, 'text' => 'Test for Client2:failure' }     
      ]
      @test_status.active = true
      @test_status.should_receive(:save!)
      @log_inspector.run
      @test_status.active.should == false
    end

    it "sets status to down when there is one client which has a most recent down event" do
      @mock_log = [
        { 'timestamp' => 5.minutes.ago.to_s, 'text' => 'Test for Client1:failure' },
        { 'timestamp' => 10.minutes.ago.to_s, 'text' => 'Test for Client1:success' }     
      ]
      @test_status.active = true
      @test_status.should_receive(:save!)
      @log_inspector.run
      @test_status.active.should == false
    end

    it "sets status to up when there is a mix of clients and no down event is more recent than a matching up event" do
      @mock_log = [
        { 'timestamp' => 5.minutes.ago.to_s, 'text' => 'Test for Client1:success' },
        { 'timestamp' => 6.minutes.ago.to_s, 'text' => 'Test for Client2:success' },
        { 'timestamp' => 7.minutes.ago.to_s, 'text' => 'Test for Client1:failure' },     
        { 'timestamp' => 8.minutes.ago.to_s, 'text' => 'Test for Client2:failure' }     
      ]
      @test_status.active = false
      @test_status.should_receive(:save!)
      @log_inspector.run
      @test_status.active.should == true
    end

    it "sets status to down when there is a mix of clients and there is a most-recent down event" do
      @mock_log = [
        { 'timestamp' => 5.minutes.ago.to_s, 'text' => 'Test for Client1:success' },
        { 'timestamp' => 6.minutes.ago.to_s, 'text' => 'Test for Client2:failure' },
        { 'timestamp' => 7.minutes.ago.to_s, 'text' => 'Test for Client1:failure' },     
        { 'timestamp' => 8.minutes.ago.to_s, 'text' => 'Test for Client2:success' }     
      ]
      @test_status.active = true
      @test_status.should_receive(:save!)
      @log_inspector.run
      @test_status.active.should == false
    end 

    it "sets status to down when there are two different clients and one has a down event with no up event" do
      @mock_log = [
        { 'timestamp' => 5.minutes.ago.to_s, 'text' => 'Test for Client1:success' },
        { 'timestamp' => 10.minutes.ago.to_s, 'text' => 'Test for Client2:failure' }
      ]
      @test_status.active = true
      @test_status.should_receive(:save!)
      @log_inspector.run
      @test_status.active.should == false
    end
  end

  describe "when saving a status object" do

    it "throws an error if saved with multiple beginning wildcards" do
      @test_status = LogInspector::LogStatus.new(:search_string_begin => ['Wildcard [*] 1', 'Another [*] Wildcard'])
      lambda { @test_status.save! }.should raise_error
    end

    it "throws an error if saved with multiple ending wildcards" do
      @test_status = LogInspector::LogStatus.new(:search_string_end => ['Wildcard [*] 1', 'Another [*] Wildcard'])
      lambda { @test_status.save! }.should raise_error
    end

    it "throws an error if the beginning string has a wildcard and the ending string does not" do
      @test_status = LogInspector::LogStatus.new(:search_string_begin => ['Wildcard [*] pattern'], :search_string_end => ['Regular pattern'])
      lambda { @test_status.save! }.should raise_error
    end

    it "throws an error if the ending string has a wildcard and the beginning string does not" do
      @test_status = LogInspector::LogStatus.new(:search_string_begin => ['Regular pattern'], :search_string_end => ['Wildcard [*] pattern'])
      lambda { @test_status.save! }.should raise_error
    end
  end
end
