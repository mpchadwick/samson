# frozen_string_literal: true
module Kubernetes
  class DeployGroupRole < ActiveRecord::Base
    self.table_name = 'kubernetes_deploy_group_roles'

    audited

    belongs_to :project
    belongs_to :deploy_group
    belongs_to :kubernetes_role, class_name: 'Kubernetes::Role'

    validates :requests_cpu, :requests_memory, :limits_memory, :limits_cpu, :replicas, presence: true
    validates :requests_cpu, numericality: { greater_than_or_equal_to: 0 }
    validates :limits_cpu, numericality: { greater_than: 0 }
    validates :requests_memory, :limits_memory, numericality: { greater_than_or_equal_to: 4 }
    validate :requests_below_limits
    validate :requests_below_usage_limits

    # The matrix is a list of deploy group and its roles + deploy-group-roles
    def self.matrix(stage)
      project_dg_roles = Kubernetes::DeployGroupRole.where(
        project_id: stage.project_id,
        deploy_group_id: stage.deploy_groups.map(&:id)
      ).to_a
      roles = stage.project.kubernetes_roles.not_deleted.sort_by(&:name)

      stage.deploy_groups.sort_by(&:natural_order).map do |deploy_group|
        dg_roles = project_dg_roles.select { |r| r.deploy_group_id == deploy_group.id }
        role_pairs = roles.map do |role|
          [role, dg_roles.detect { |r| r.kubernetes_role_id == role.id }]
        end
        [deploy_group, role_pairs]
      end
    end

    def self.usage
      query = select(<<-SQL).group(:deploy_group_id)
        sum(requests_cpu * replicas) as cpu,
        sum(requests_memory * replicas) as memory,
        max(deploy_group_id) as deploy_group_id
      SQL
      connection.select_all(query).each_with_object({}) do |values, all|
        all[values.fetch("deploy_group_id")] = values
      end
    end

    # add deploy group roles for everything missing from the matrix
    # returns:
    #  - everything was created: true
    #  - some could not be created because of missing configs: false
    #  - failed to create because of unknown errors: raises
    def self.seed!(stage)
      missing = matrix(stage).each_with_object([]) do |(deploy_group, roles), all|
        roles.each do |role, dg_role|
          all << [deploy_group, role] unless dg_role
        end
      end

      missing.map do |deploy_group, role|
        if defaults = role.defaults
          replicas = defaults.fetch(:replicas)
          requests_cpu = defaults.fetch(:requests_cpu)
          requests_memory = defaults.fetch(:requests_memory)

          if replicas.nonzero? && usage_limit = Kubernetes::UsageLimit.most_specific(role.project, deploy_group)
            requests_cpu = [usage_limit.cpu / replicas, requests_cpu].min if usage_limit.cpu > 0
            requests_memory = [usage_limit.memory / replicas, requests_memory].min if usage_limit.memory > 0
          end

          create(
            project: stage.project,
            deploy_group: deploy_group,
            kubernetes_role: role,
            replicas: replicas,
            requests_cpu: requests_cpu,
            requests_memory: requests_memory,
            limits_cpu: defaults.fetch(:limits_cpu),
            limits_memory: defaults.fetch(:limits_memory)
          )
        else
          dgr = DeployGroupRole.new(kubernetes_role: role, deploy_group: deploy_group)
          dgr.errors.add(:base, "Role has no defaults")
          dgr
        end
      end
    end

    def requests_below_limits
      if limits_cpu && requests_cpu > limits_cpu
        errors.add :requests_cpu, "must be less than or equal to the limit"
      end
      if limits_memory && requests_memory > limits_memory
        errors.add :requests_memory, "must be less than or equal to the limit"
      end
    end

    def requests_below_usage_limits
      return unless limit = UsageLimit.most_specific(project, deploy_group)
      message = "must be less than or equal to kubernetes usage limit"
      usage_limit_warning = ENV["KUBERNETES_USAGE_LIMIT_WARNING"]
      usage_limit_warning = ". #{usage_limit_warning}" if usage_limit_warning
      if requests_cpu * replicas > limit.cpu
        errors.add(
          :requests_cpu,
          "(#{requests_cpu} * #{replicas}) #{message} #{limit.cpu} (##{limit.id})#{usage_limit_warning}"
        )
      end
      if requests_memory * replicas > limit.memory
        errors.add(
          :requests_memory,
          "(#{requests_memory} * #{replicas}) #{message} #{limit.memory} (##{limit.id})#{usage_limit_warning}"
        )
      end
    end
  end
end
