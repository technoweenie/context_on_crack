module ContextOnCrack
  module ControllerExampleGroupMethods
    def self.extended(base)
      base.send :include, InstanceMethods
    end

    def describe_access(&block)
      ContextOnCrack::ControllerAccessProxy.new(self, controller_class).instance_eval(&block)
    end

    def describe_requests(&block)
      ContextOnCrack::ControllerRequestProxy.new(self, controller_class).instance_eval(&block)
    end

    module InstanceMethods
      def acting(&block)
        act!
        block.call(@response) if block
        @response
      end
    
      def act!
        instance_eval &@acting_block
      end
    
    protected
      def asserts_content_type(type = :html)
        mime = Mime::Type.lookup_by_extension((type || :html).to_s)
        assert_equal mime, @response.content_type, "Renders with Content-Type of #{@response.content_type}, not #{mime}"
      end
    
      def asserts_status(status)
        case status
        when String, Fixnum
          assert_equal status.to_s, @response.code, "Renders with status of #{@response.code.inspect}, not #{status}"
        when Symbol
          code_value = ActionController::StatusCodes::SYMBOL_TO_STATUS_CODE[status]
          assert_equal code_value.to_s, @response.code, "Renders with status of #{@response.code.inspect}, not #{code_value.inspect} (#{status.inspect})"
        else
          assert_equal "200", @response.code, "Is not successful"
        end
      end
    end
  end

  class ControllerProxy
    attr_reader :test_case

    def initialize(test_case, controller, context_name)
      @test_case, @controller = test_case.context(context_name) {}, controller
    end

  protected
    def method_missing(m, *args, &block)
      @test_case.send m, *args, &block
    end
  end

  class ControllerGroup
    def initialize(proxy)
      @proxy = proxy
    end

  protected
    def method_missing(m, *args, &block)
      @proxy.test_case.send(m, *args, &block)
    end
  end

  class ControllerAccessProxy < ControllerProxy
    def initialize(test_case, controller)
      super test_case, controller, "access"
    end

    def as(*users, &block)
      users.each do |user|
        ControllerAccessGroup.new(self, user).instance_eval(&block)
      end
    end
  end

  class ControllerAccessGroup < ControllerGroup
    def initialize(proxy, user)
      super(proxy)
      @user = user
    end

    def it_performs(description, method, actions, params = {}, &block)
      Array(actions).each do |action|
        param_desc = (params.respond_to?(:call) && params.respond_to?(:to_ruby)) ?
          params.to_ruby.gsub(/(^proc \{)|(\}$)/, '').strip :
          params.inspect
        action_user = @user
        it "#{description} for @#{@user}: #{method.to_s.upcase} #{action} #{param_desc}".strip do
          stub(@controller).current_user { action_user == :anon ? nil : instance_variable_get("@#{action_user}") }
          stub(@controller).logged_in?   { action_user != :anon }
          meta = class << @controller ; self ; end
          meta.send(:define_method, action) { head :ok }
          send method, action, params.respond_to?(:call) ? instance_eval(&params) : params
          instance_eval &block
        end
      end
    end
    
    def it_allows(method, actions, params = {}, &block_params)
      it_performs :allows, method, actions, block_params || params do
        assert_equal "200", @response.code, "Is not successful"
      end
    end

    def it_restricts(method, actions, params = {}, &block_params)
      it_performs :restricts, method, actions, block_params || params do
        assert_redirected_to new_session_path
      end
    end
  end

  class ControllerRequestProxy < ControllerProxy
    def initialize(test_case, controller)
      super test_case, controller, "request"
    end

    def context(description, &block)
      ControllerRequestGroup.new(self, "#{@controller.name} #{description}", @before_blocks, @after_blocks).instance_eval(&block)
    end
  end

  class ControllerRequestGroup < ControllerGroup
    @@variable_types = {:headers => :to_s, :flash => nil, :session => nil}

    def initialize(proxy, prefix, before_blocks, after_blocks)
      super(proxy)
      @prefix = prefix
      @acting_block  = nil
      @before_blocks = before_blocks.nil? ? [] : before_blocks.dup
      @after_blocks  = after_blocks.nil? ? [] : after_blocks.dup
    end

    def acting_block
      @acting_block
    end

    def act!(&block)
      @acting_block = block
    end

    def before(period = :each, &block)
      raise "only before(:each) allowed in controller request proxy tests" if period != :each
      @before_blocks << block
    end

    def after(period = :each, &block)
      raise "only after(:each) allowed in controller request proxy tests" if period != :each
      @after_blocks << block
    end

    def context(description, &block)
      ControllerRequestGroup.new(@proxy, "#{@prefix} #{description}", @before_blocks, @after_blocks).instance_eval(&block)
    end

    def it(description, &block)
      before_blocks      = @before_blocks
      group_acting_block = @acting_block
      after_blocks       = @after_blocks
      @proxy.test_case.it("#{@prefix} #{description}") do
        @acting_block = group_acting_block
        before_blocks.each { |b| instance_eval &b }
        instance_eval &block
        after_blocks.each { |b| instance_eval &b }
      end
    end

    # Checks that the action redirected:
    #
    #   it_redirects_to { foo_path(@foo) }
    # 
    # Provide a better hint than Proc#inspect
    #
    #   it_redirects_to("foo_path(@foo)") { foo_path(@foo) }
    #
    def it_redirects_to(hint = nil, &route)
      if hint.nil? && route.respond_to?(:to_ruby)
        hint = route.to_ruby.gsub(/(^proc \{)|(\}$)/, '').strip
      end

      it "redirects to #{(hint || route).inspect}" do
        act!
        assert_redirected_to instance_eval(&route)
      end
    end

    # Check that an instance variable was set to the instance variable of the same name 
    # in the Spec Example:
    #
    #   it_assigns :foo # => assigns[:foo].should == @foo
    #
    # If there is no instance variable @foo, it will just check to see if its not nil:
    #
    #   it_assigns :foo # => assigns[:foo].should_not be_nil (if @foo is not defined in spec)
    #
    # Check multiple instance variables
    # 
    #   it_assigns :foo, :bar
    #
    # Check the instance variable was set to something more specific
    #
    #   it_assigns :foo => 'bar'
    #
    # Check both instance variables:
    #
    #   it_assigns :foo, :bar => 'bar'
    #
    # Check the instance variable is not nil:
    #
    #   it_assigns :foo => :not_nil # assigns[:foo].should_not be_nil
    #
    # Check the instance variable is nil
    #
    #   it_assigns :foo => nil # => assigns[:foo].should be_nil
    #
    # Check the instance variable was not set at all
    #
    #   it_assigns :foo => :undefined # => controller.send(:instance_variables).should_not include("@foo")
    #
    # Instance variables for :headers/:flash/:session are special and use the assigns_* methods.
    #
    #   it_assigns :foo => 'bar', 
    #     :headers => { :Location => '...'    }, # it.assigns_headers :Location => ...
    #     :flash   => { :notice   => :not_nil }, # it.assigns_flash :notice => ...
    #     :session => { :user     => 1        }, # it.assigns_session :user => ...
    #
    def it_assigns(*names)
      names.each do |name|
        if name.is_a?(Symbol)
          it_assigns name => name # go forth and recurse!
        elsif name.is_a?(Hash)
          name.each do |key, value|
            if @@variable_types.key?(key) then send("it_assigns_#{key}", value)
            else it_assigns_example_values(key, value) end
          end
        end
      end
    end
  
    # See protected #render_blank, #render_template, and #render_xml for details.
    #
    #   it_renders :blank
    #   it_renders :template, :new
    #   it_renders :xml, :foo
    #
    def it_renders(render_method, *args, &block)
      send("it_renders_#{render_method}", *args, &block)
    end
  
    # Check that the flash variable(s) were assigned
    #
    #   it_assigns_flash :notice => 'foo',
    #     :this_is_nil => nil,
    #     :this_is_undefined => :undefined,
    #     :this_is_set => :not_nil
    #
    def it_assigns_flash(flash)
      raise NotImplementedError
    end
    
    # Check that the session variable(s) were assigned
    #
    #   it_assigns_session :notice => 'foo',
    #     :this_is_nil => nil,
    #     :this_is_undefined => :undefined,
    #     :this_is_set => :not_nil
    #
    def it_assigns_session(session)
      raise NotImplementedError
    end
    
    # Check that the HTTP header(s) were assigned
    #
    #   it.assigns_headers :Location => 'foo',
    #     :this_is_nil => nil,
    #     :this_is_undefined => :undefined,
    #     :this_is_set => :not_nil
    #
    def it_assigns_headers(headers)
      raise NotImplementedError
    end
    
    @@variable_types.each do |collection_type, collection_op|
      public
      define_method "it_assigns_#{collection_type}" do |values|
        values.each do |key, value|
          send("it_assigns_#{collection_type}_values", key, value)
        end
      end
      
      protected
      define_method "it_assigns_#{collection_type}_values" do |key, value|
        key = key.send(collection_op) if collection_op
        it "assigns #{collection_type}[#{key.inspect}]" do
          acting do |resp|
            collection = resp.send(collection_type)
            case value
              when nil
                assert_nil collection[key]
              when :not_nil
                assert_not_nil collection[key]
              when :undefined
                assert !collection.include?(key), "#{collection_type} includes #{key}"
              when Proc
                assert_equal instance_eval(&value), collection[key]
              else
                assert_equal value, collection[key]
            end
          end
        end
      end
    end
    
    public

    def it_assigns_example_values(name, value)
      it "assigns @#{name}" do
        act!
        value = 
          case value
          when :not_nil
            assert_not_nil assigns(name), "@#{name} is nil"
          when :undefined
            assert !@controller.send(:instance_variables).include?("@#{name}"), "@#{name} is defined"
          when Symbol
            if (instance_variable = instance_variable_get("@#{value}")).nil?
              assert_not_nil assigns(name)
            else
              assert_equal instance_variable, assigns(name)
            end
          end
      end
    end

    # Creates 2 examples:  One to check that the body is blank,
    # and the other to check the status.  It looks for one option:
    # :status.  If unset, it checks that that the response was a success.
    # Otherwise it takes an integer or a symbol and matches the status code.
    #
    #   it_renders :blank
    #   it_renders :blank, :status => :not_found
    #
    def it_renders_blank(options = {})
      it "renders a blank response" do
        acting do |response|
          asserts_status options[:status]
          assert @response.body.strip.blank?
        end
      end
    end
    
    # Creates 3 examples: One to check that the given template was rendered.
    # It looks for two options: :status and :format.
    #
    #   it_renders :template, :index
    #   it_renders :template, :index, :status => :not_found
    #   it_renders :template, :index, :format => :xml
    #
    # If :status is unset, it checks that that the response was a success.
    # Otherwise it takes an integer or a symbol and matches the status code.
    #
    # If :format is unset, it checks that the action is Mime:HTML.  Otherwise
    # it attempts to match the mime type using Mime::Type.lookup_by_extension.
    #
    def it_renders_template(template_name, options = {})
      it "renders #{template_name}" do
        acting do |response|
          asserts_status options[:status]
          asserts_content_type options[:format]
          assert_template template_name.to_s
        end
      end
    end
    
    # Creates 3 examples: One to check that the given XML was returned.
    # It looks for two options: :status and :format.
    #
    # Checks that the xml matches a given string
    #
    #   it_renders(:xml) { "<foo />" }
    #
    # Checks that the xml matches @foo.to_xml
    #
    #   it_renders :xml, :foo
    #
    # Checks that the xml matches @foo.errors.to_xml
    #
    #   it_renders :xml, "foo.errors"
    #
    #   it_renders :xml, :index, :status => :not_found
    #   it_renders :xml, :index, :format => :xml
    #
    # If :status is unset, it checks that that the response was a success.
    # Otherwise it takes an integer or a symbol and matches the status code.
    #
    # If :format is unset, it checks that the action is Mime:HTML.  Otherwise
    # it attempts to match the mime type using Mime::Type.lookup_by_extension.
    #
    def it_renders_xml(record = nil, options = {}, &block)
      it_renders_xml_or_json :xml, record, options, &block
    end
    
    # Creates 3 examples: One to check that the given JSON was returned.
    # It looks for two options: :status and :format.
    #
    # Checks that the json matches a given string
    #
    #   it_renders(:json) { "{}" }
    #
    # Checks that the json matches @foo.to_json
    #
    #   it_renders :json, :foo
    #
    # Checks that the json matches @foo.errors.to_json
    #
    #   it_renders :json, "foo.errors"
    #
    #   it_renders :json, :index, :status => :not_found
    #   it_renders :json, :index, :format => :json
    #
    # If :status is unset, it checks that that the response was a success.
    # Otherwise it takes an integer or a symbol and matches the status code.
    #
    # If :format is unset, it checks that the action is Mime:HTML.  Otherwise
    # it attempts to match the mime type using Mime::Type.lookup_by_extension.
    #
    def it_renders_json(record = nil, options = {}, &block)
      it_renders_xml_or_json :json, record, options, &block
    end
    
    def it_renders_xml_or_json(format, record = nil, options = {}, &block)
      if record.is_a?(Hash)
        options = record
        record  = nil
      end

      it "renders #{format}" do
        if record
          pieces = record.to_s.split(".")
          record = instance_variable_get("@#{pieces.shift}")
          record = record.send(pieces.shift) until pieces.empty?
          block ||= lambda { record.send("to_#{format}") }
        end

        acting do |response|
          asserts_status options[:status]
          asserts_content_type options[:format] || format
          if block
            assert false, "no response.should have_text"
            response.should have_text(block.call)
          end
        end
      end
    end
  end
end
