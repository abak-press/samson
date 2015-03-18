module Authorization
  extend ActiveSupport::Concern

  included do
    helper_method :authorize_super_admin!
    helper_method :authorize_admin!
    helper_method :authorize_deployer!
    helper_method :unauthorized!
  end

  def authorize_super_admin!
    unauthorized! unless current_user.is_super_admin?
  end

  def authorize_admin!
    unauthorized! unless current_user.is_admin?
  end

  def authorize_deployer!
    unauthorized! unless current_user.is_deployer?

    if respond_to?(:stage, true) && send(:stage).name[/production/i].present? && !current_user.is_admin?
      unauthorized!
    end
  end

  def unauthorized!
    # Eventually to UnauthorizedController
    throw(:warden)
  end
end
