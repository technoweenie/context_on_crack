require "context_on_crack/controller_example_group_methods"

begin
  require 'ruby2ruby'
rescue LoadError
  # no pretty example descriptions for you
end

class ActionController::TestSession
  def include?(key)
    data.include?(key)
  end
end

class ActionController::TestCase
  extend ContextOnCrack::ControllerExampleGroupMethods
  def self.inherited(child)
    child.controller_class = controller_class unless self == ActionController::TestCase
    super
  end
end