# encoding: utf-8

require "katello_test_helper"

module Katello
  class Api::V2::HostSubscriptionsControllerBase < ActionController::TestCase
    include Support::ForemanTasks::Task
    tests Katello::Api::V2::HostSubscriptionsController

    def models
      @host = FactoryBot.create(:host, :with_subscription)
      users(:restricted).update_attribute(:organizations, [@host.organization])
      users(:restricted).update_attribute(:locations, [@host.location])
      @pool = katello_pools(:pool_one)
      @entitlements = [{:pool => {:id => @pool.cp_id}, :quantity => '3'}.with_indifferent_access]
    end

    def permissions
      @view_permission = :view_hosts
      @create_permission = :create_hosts
      @update_permission = :edit_hosts
      @destroy_permission = :destroy_hosts
    end

    def backend_stubs
      Katello::Pool.any_instance.stubs(:pool_facts).returns({})
      Katello::Candlepin::Consumer.any_instance.stubs(:entitlements).returns(@entitlements)
    end

    def setup
      setup_controller_defaults_api
      setup_foreman_routes
      login_user(users(:admin))

      models
      backend_stubs
      permissions
    end
  end

  class Api::V2::HostSubscriptionsControllerTest < Api::V2::HostSubscriptionsControllerBase
    include FactImporterIsolation

    allow_transactions_for_any_importer

    def test_index
      get :index, params: { :host_id => @host.id }

      assert_response :success
      assert_template 'api/v2/host_subscriptions/index'
    end

    def test_index_bad_system
      @host = FactoryBot.create(:host)

      get :index, params: { :host_id => @host.id }

      assert_response 400
    end

    def test_index_protected
      allowed_perms = [@view_permission]
      denied_perms = [@create_permission, @update_permission, @destroy_permission]

      assert_protected_action(:index, allowed_perms, denied_perms) do
        get :index, params: { :host_id => @host.id }
      end
    end

    def test_auto_attach
      Organization.any_instance.stubs(:simple_content_access?).returns(false)
      assert_sync_task(::Actions::Katello::Host::AutoAttachSubscriptions, @host)
      put :auto_attach, params: { :host_id => @host.id }

      assert_response :success
      assert_template 'api/v2/host_subscriptions/index'
    end

    def test_auto_attach_simple_content_access
      Organization.any_instance.stubs(:simple_content_access?).returns(true)
      put :auto_attach, params: { :host_id => @host.id }

      assert_response(400, "This host's organization is in Simple Content Access mode. Auto-attach is disabled")
    end

    def test_auto_attach_protected
      allowed_perms = [@update_permission]
      denied_perms = [@create_permission, @view_permission, @destroy_permission]

      assert_protected_action(:auto_attach, allowed_perms, denied_perms) do
        put :auto_attach, params: { :host_id => @host.id }
      end
    end

    def test_add_subscriptions
      Organization.any_instance.stubs(:simple_content_access?).returns(false)
      assert_sync_task(::Actions::Katello::Host::AttachSubscriptions) do |host, pools_with_quantities|
        assert_equal @host, host
        assert_equal 1, pools_with_quantities.count
        assert_equal @pool, pools_with_quantities[0].pool
        assert_equal [1], pools_with_quantities[0].quantities.map(&:to_i)
      end

      post :add_subscriptions, params: { :host_id => @host.id, :subscriptions => [{:id => @pool.id, :quantity => "1"}] }

      assert_response :success
      assert_template 'api/v2/host_subscriptions/index'
    end

    def test_add_subscriptions_protected
      allowed_perms = [@update_permission]
      denied_perms = [@view_permission, @create_permission, @destroy_permission]

      assert_protected_action(:add_subscriptions, allowed_perms, denied_perms) do
        post :add_subscriptions, params: { :host_id => @host.id, :subscriptions => [{:id => @pool.id, :quantity => 1}] }
      end
    end

    def test_remove_subscriptions
      assert_sync_task(::Actions::Katello::Host::RemoveSubscriptions) do |host, pools_with_quantities|
        assert_equal @host, host
        assert_equal "1", pools_with_quantities.count.to_s
        assert_equal @pool, pools_with_quantities[0].pool
        assert_equal [3], pools_with_quantities[0].quantities.map(&:to_i)
      end
      post :remove_subscriptions, params: { :host_id => @host.id, :subscriptions => [{:id => @pool.id, :quantity => '3'}] }

      assert_response :success
      assert_template 'api/v2/host_subscriptions/index'
    end

    def test_remove_subscriptions_protected
      allowed_perms = [@update_permission]
      denied_perms = [@view_permission, @create_permission, @destroy_permission]

      assert_protected_action(:remove_subscriptions, allowed_perms, denied_perms) do
        post :remove_subscriptions, params: { :host_id => @host.id, :subscriptions => [{:id => @pool.id, :quantity => 3}] }
      end
    end

    def test_create
      facts = { 'network.hostname' => @host.name}
      installed_products = [{
        'product_id' => '1',
        'product_name' => 'name'
      }]
      expected_consumer_params = {
        'type' => 'system',
        'role' => 'MyRole',
        'usage' => 'MyUsage',
        'addOns' => 'Addon1,Addon2',
        'facts' => facts,
        'installedProducts' => [{
          'productId' => '1',
          'productName' => 'name'
        }]
      }
      content_view_environment = ContentViewEnvironment.find(katello_content_view_environments(:library_default_view_environment).id)
      Resources::Candlepin::Consumer.stubs(:get)

      ::Katello::RegistrationManager.expects(:process_registration).with(expected_consumer_params, content_view_environment).returns(@host)
      post(:create,
        params: {
          :lifecycle_environment_id => content_view_environment.environment_id,
          :content_view_id => content_view_environment.content_view_id,
          :facts => facts,
          :installed_products => installed_products,
          :purpose_role => 'MyRole',
          :purpose_usage => 'MyUsage',
          :purpose_addons => 'Addon1,Addon2'
        }
      )

      assert_response :success
    end

    def test_create_dead_backend
      facts = { 'network.hostname' => @host.name}
      installed_products = [{
        'product_id' => '1',
        'product_name' => 'name'
      }]
      content_view_environment = ContentViewEnvironment.find(katello_content_view_environments(:library_default_view_environment).id)

      ::Katello::RegistrationManager.expects(:check_registration_services).returns(false)

      ::Katello::Host::SubscriptionFacet.expects(:find_or_create_host).never
      ::Katello::RegistrationManager.expects(:register_host).never
      post(:create, params: { :lifecycle_environment_id => content_view_environment.environment_id,
                              :content_view_id => content_view_environment.content_view_id,
                              :facts => facts, :installed_products => installed_products })

      assert_response 500
    end
  end

  class Api::V2::HostSubscriptionsProductContentTest < Api::V2::HostSubscriptionsControllerBase
    def setup
      super
      content = FactoryBot.build(:katello_content, label: 'some-content')
      pc = [FactoryBot.build(:katello_product_content, content: content)]
      ::Katello::Candlepin::Consumer.any_instance.stubs(:available_product_content).returns(pc)
      Katello::Candlepin::Consumer.any_instance.stubs(:content_overrides).returns([])
      ProductContentFinder.any_instance.stubs(:product_content).returns(pc)
    end

    def test_product_content_protected
      allowed_perms = [@view_permission]
      denied_perms = [@update_permission, @create_permission, @destroy_permission]

      assert_protected_action(:product_content, allowed_perms, denied_perms) do
        get(:product_content, params: { :host_id => @host.id })
      end
    end

    def test_product_content
      result = get(:product_content, params: { :host_id => @host.id })
      content = JSON.parse(result.body)['results'][0]['content']

      assert_equal('some-content', content['label'])
      assert_response :success
      assert_template 'api/v2/host_subscriptions/product_content'
    end

    def test_product_content_access_mode_all
      mode_all = true
      mode_env = false
      result = get(:product_content, params: { :host_id => @host.id, :content_access_mode_all => mode_all, :content_view_version_env => mode_env })
      content = JSON.parse(result.body)['results'][0]['content']

      assert_equal('some-content', content['label'])
      assert_response :success
      assert_template 'api/v2/host_subscriptions/product_content'
    end

    def test_content_override_protected
      allowed_perms = [@update_permission]
      denied_perms = [@view_permission, @create_permission, @destroy_permission]

      assert_protected_action(:content_override, allowed_perms, denied_perms) do
        put(:content_override, params: { :host_id => @host.id, :content_label => 'some-content', :value => 1 })
      end
    end

    def test_content_override
      content_overrides = [{:content_label => 'some-content', :value => 1}]
      value = "1"
      assert_sync_task(::Actions::Katello::Host::UpdateContentOverrides) do |host, overrides, prune_invalid|
        assert_equal @host, host
        assert_equal 1, overrides.count
        assert_equal 'some-content', overrides.first.content_label
        refute prune_invalid
        assert_equal value, overrides.first.value
      end

      put :content_override, params: { :host_id => @host.id, :content_overrides => content_overrides }

      assert_response :success
      assert_template 'api/v2/host_subscriptions/content_override'
    end

    def test_content_override_bulk
      content_overrides = [{:content_label => 'some-content', :value => 1}]
      expected_content_labels = content_overrides.map { |co| co[:content_label] }
      assert_sync_task(::Actions::Katello::Host::UpdateContentOverrides) do |host, overrides, prune_invalid|
        assert_equal @host, host
        assert_equal content_overrides.count, overrides.count
        refute prune_invalid
        assert_equal expected_content_labels, overrides.map(&:content_label)
      end

      put :content_override, params: { :host_id => @host.id, :content_overrides => content_overrides }

      assert_response :success
      assert_template 'api/v2/host_subscriptions/content_override'
    end

    def test_content_override_accepts_string_values
      content_overrides = [{:content_label => 'some-content', :value => 1}]
      value = "1"
      assert_sync_task(::Actions::Katello::Host::UpdateContentOverrides) do |host, overrides, _|
        assert_equal @host, host
        assert_equal 1, overrides.count
        assert_equal 'some-content', overrides.first.content_label
        assert_equal value, overrides.first.value
      end

      put :content_override, params: { :host_id => @host.id, :content_overrides => content_overrides, :value => 'yes' }

      assert_response :success
    end

    # content overrides may be added before the host has access to the content
    def test_invalid_content_succeeds
      content_overrides = [{:content_label => 'wrong-content', :value => 1}]
      value = "1"
      assert_sync_task(::Actions::Katello::Host::UpdateContentOverrides) do |host, overrides, prune_invalid|
        assert_equal @host, host
        assert_equal 1, overrides.count
        assert_equal 'wrong-content', overrides.first.content_label
        refute prune_invalid
        assert_equal value, overrides.first.value
      end

      put :content_override, params: { :host_id => @host.id, :content_overrides => content_overrides, :value => value }

      assert_response :success
      assert_template 'api/v2/host_subscriptions/content_override'
    end

    def test_available_release_versions
      get :available_release_versions, params: { :host_id => @host.id }

      assert_response :success
    end

    def test_destroy
      ::Katello::RegistrationManager.expects(:unregister_host).with(@host, :unregistering => true)

      delete :destroy, params: { :host_id => @host.id }

      assert_response :success
    end
  end
end
