# frozen_string_literal: true

module SamsonKubernetes
  class Engine < Rails::Engine
    initializer "refinery.assets.precompile" do |app|
      app.config.assets.precompile.append %w[kubernetes/icon.png]
    end
  end

  # http errors and ssl errors are not handled uniformly, but we want to ignore/retry on both
  # see https://github.com/abonas/kubeclient/issues/240
  # using a method to avoid loading kubeclient on every boot ~0.1s
  def self.connection_errors
    [OpenSSL::SSL::SSLError, KubeException, Errno::ECONNREFUSED].freeze
  end

  def self.retry_on_connection_errors
    yield
  rescue *connection_errors
    retries ||= 3
    retries -= 1
    raise if retries < 0
    retry
  end
end

Samson::Hooks.view :project_tabs_view, 'samson_kubernetes/project_tab'
Samson::Hooks.view :manage_menu, 'samson_kubernetes/manage_menu'
Samson::Hooks.view :stage_form, "samson_kubernetes/stage_form"
Samson::Hooks.view :stage_show, "samson_kubernetes/stage_show"
Samson::Hooks.view :deploy_tab_nav, "samson_kubernetes/deploy_tab_nav"
Samson::Hooks.view :deploy_tab_body, "samson_kubernetes/deploy_tab_body"
Samson::Hooks.view :deploy_form, "samson_kubernetes/deploy_form"
Samson::Hooks.view :deploy_group_show, "samson_kubernetes/deploy_group_show"
Samson::Hooks.view :deploy_group_form, "samson_kubernetes/deploy_group_form"
Samson::Hooks.view :deploy_group_table_header, "samson_kubernetes/deploy_group_table_header"
Samson::Hooks.view :deploy_group_table_cell, "samson_kubernetes/deploy_group_table_cell"

Samson::Hooks.callback :deploy_group_permitted_params do
  { cluster_deploy_group_attributes: [:kubernetes_cluster_id, :namespace] }
end
Samson::Hooks.callback(:stage_permitted_params) { :kubernetes }
Samson::Hooks.callback(:deploy_permitted_params) { [:kubernetes_rollback, :kubernetes_reuse_build] }
Samson::Hooks.callback(:link_parts_for_resource) do
  [
    "Kubernetes::Cluster",
    ->(cluster) { [cluster.name, cluster] }
  ]
end

Samson::Hooks.callback(:link_parts_for_resource) do
  [
    "Kubernetes::DeployGroupRole",
    ->(dgr) { ["#{dgr.project&.name} role #{dgr.kubernetes_role&.name} for #{dgr.deploy_group&.name}", dgr] }
  ]
end
Samson::Hooks.callback(:link_parts_for_resource) do
  [
    "Kubernetes::Role",
    ->(role) { ["#{role.project&.name} role #{role.name}", [role.project, role]] }
  ]
end
Samson::Hooks.callback(:link_parts_for_resource) do
  [
    "Kubernetes::UsageLimit",
    ->(limit) { ["Limit for #{limit.scope&.name} on #{limit.project&.name || "All"}", limit] }
  ]
end

Samson::Hooks.callback(:deploy_group_includes) { :kubernetes_cluster }
