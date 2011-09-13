require '../log_inspector'
require 'active_support/all'

describe LogInspector do

  before(:each) do
    Loggly.any_instance.stub(:search) do |query|
      {'data' => @mock_log.select {|log_entry| Regexp.new(query.sub('[*]', '.*?')) =~ log_entry['text'] } }
    end
  end

  describe "for standard search strings" do
    before(:each) do
      # using a factory for this would be nicer
      @test_status = LogInspector::LogStatus.new
      @test_status.stub(:search_string_begin).and_return ['Test:success']
      @test_status.stub(:search_string_end).and_return ['Test:failure']
      LogInspector::LogStatus.should_receive(:find).and_return([@test_status])
    end

    describe "when the log has no matching results" do
      it "should default to an inactive status" do
        @mock_log = [
          {'timestamp' => 5.minutes.ago.to_s, 'text' => 'Not a matching log event' }
        ]
        @test_status.active = true
        LogInspector.new
        @test_status.active.should == false
      end
    end

    describe "when the log finds that the most recent event is a positive" do
   
      before(:each) do
        @mock_log = [
          {'timestamp' => 5.minutes.ago.to_s, 'text' => @test_status.search_string_begin.first },
          {'timestamp' => 10.minutes.ago.to_s, 'text' => @test_status.search_string_end.first }
        ]
      end 

      it "sets the SimpleDb status to active if it was previously inactive" do
        @test_status.active = false
        LogInspector.new
        @test_status.active.should == true
      end

      it "does not change the SimpleDb status if it was already active" do
        @test_status.active = true
        @test_status.should_not_receive(:active=)
        @test_status.should_not_receive(:save!)
        LogInspector.new
      end
    end

    describe "when the log finds that the most recent event is a failure" do

      before(:each) do
        @mock_log = [
          {'timestamp' => 5.minutes.ago.to_s, 'text' => @test_status.search_string_end.first },
          {'timestamp' => 10.minutes.ago.to_s, 'text' => @test_status.search_string_begin.first }
        ]
      end 

      it "sets the SimpleDb status to inactive if it was previously active" do
        @test_status.active = true
        LogInspector.new
        @test_status.active.should == false
      end

      it "does not change the SimpleDb status if it was already inactive" do
        @test_status.active = false
        @test_status.should_not_receive(:active=)
        @test_status.should_not_receive(:save!)
        LogInspector.new
      end
    end
  end

  describe "when wildcard search strings are used" do

    before(:each) do
      @test_status = LogInspector::LogStatus.new
      @test_status.stub(:search_string_begin).and_return ['Test for [*]:success']
      @test_status.stub(:search_string_end).and_return ['Test for [*]:failure']
      LogInspector::LogStatus.should_receive(:find).and_return([@test_status])
    end 

    it "throws an exception if you try to use multiple wildcard patterns in the starting patterns" do
      @test_status.stub(:search_string_begin).and_return ['Test for [*]:success', 'Another wildcard[*]']
      lambda { LogInspector.new }.should raise_error
    end

    it "throws an exception if you try to use multiple wildcard patterns in the ending patterns" do
      @test_status.stub(:search_string_end).and_return ['Test for [*]:success', 'Another wildcard[*]']
      lambda { LogInspector.new }.should raise_error
    end
    
    it "reports success when there are no failures in the log" do
      @mock_log = [
        { 'timestamp' => 5.minutes.ago.to_s, 'text' => 'Test for Client1:success' },
        { 'timestamp' => 10.minutes.ago.to_s, 'text' => 'Test for Client2:success' }     
      ]
      @test_status.active = false
      @test_status.should_receive(:save!)
      LogInspector.new
      @test_status.active.should == true
    end

    it "reports success when there is one client which has a most recent success" do
      @mock_log = [
        { 'timestamp' => 5.minutes.ago.to_s, 'text' => 'Test for Client1:success' },
        { 'timestamp' => 10.minutes.ago.to_s, 'text' => 'Test for Client1:failure' }     
      ]
      @test_status.active = false
      @test_status.should_receive(:save!)
      LogInspector.new
      @test_status.active.should == true
    end

    it "reports failure when the are no successes in the log" do
      @mock_log = [
        { 'timestamp' => 5.minutes.ago.to_s, 'text' => 'Test for Client1:failure' },
        { 'timestamp' => 10.minutes.ago.to_s, 'text' => 'Test for Client2:failure' }     
      ]
      @test_status.active = true
      @test_status.should_receive(:save!)
      LogInspector.new
      @test_status.active.should == false
    end

    it "reports failure when there is one client which has a most recent failure" do
      @mock_log = [
        { 'timestamp' => 5.minutes.ago.to_s, 'text' => 'Test for Client1:failure' },
        { 'timestamp' => 10.minutes.ago.to_s, 'text' => 'Test for Client1:success' }     
      ]
      @test_status.active = true
      @test_status.should_receive(:save!)
      LogInspector.new
      @test_status.active.should == false
    end

    it "reports success when there is a mix of clients and no failure is more recent than a matching success" do
      @mock_log = [
        { 'timestamp' => 5.minutes.ago.to_s, 'text' => 'Test for Client1:success' },
        { 'timestamp' => 6.minutes.ago.to_s, 'text' => 'Test for Client2:success' },
        { 'timestamp' => 7.minutes.ago.to_s, 'text' => 'Test for Client1:failure' },     
        { 'timestamp' => 8.minutes.ago.to_s, 'text' => 'Test for Client2:failure' }     
      ]
      @test_status.active = false
      @test_status.should_receive(:save!)
      LogInspector.new
      @test_status.active.should == true
    end

    it "reports failure when there is a mix of clients and there is a most-recent failure" do
      @mock_log = [
        { 'timestamp' => 5.minutes.ago.to_s, 'text' => 'Test for Client1:success' },
        { 'timestamp' => 6.minutes.ago.to_s, 'text' => 'Test for Client2:failure' },
        { 'timestamp' => 7.minutes.ago.to_s, 'text' => 'Test for Client1:failure' },     
        { 'timestamp' => 8.minutes.ago.to_s, 'text' => 'Test for Client2:success' }     
      ]
      @test_status.active = true
      @test_status.should_receive(:save!)
      LogInspector.new
      @test_status.active.should == false
    end 
  end
end
