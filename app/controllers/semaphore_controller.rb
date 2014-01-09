class SemaphoreController < ActionController::Base
  skip_before_filter :login_users
  skip_before_filter :verify_authenticity_token

  rescue_from ActiveRecord::RecordNotFound do
    head :not_found
  end

  def create
    return head :ok if params[:result] != "passed"

    project = Project.find_by_token!(params[:token])
    stages = project.webhook_stages_for_branch(params[:branch_name])
    semaphore_user = User.find_or_create_by(name: "Semaphore")
    deploy_service = DeployService.new(project, semaphore_user)

    stages.each do |stage|
      deploy_service.deploy!(stage, params[:commit][:id])
    end

    head :ok
  end
end