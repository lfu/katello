require 'katello_test_helper'

module ::Actions::Katello::ContentViewVersion
  class TestBase < ActiveSupport::TestCase
    include Dynflow::Testing
    include Support::Actions::Fixtures
    include FactoryBot::Syntax::Methods
    include Support::Actions::RemoteAction
    include Support::ExportSupport
    let(:action_class) do
      ::Actions::Katello::ContentViewVersion::Import
    end

    let(:action) do
      create_action action_class
    end

    let(:content_view) do
      content_view_version.content_view
    end

    let(:content_view_version) do
      katello_content_view_versions(:library_no_filter_view_version_1)
    end

    let(:metadata) do
      prod = katello_products(:redhat)

      {
        repository_mapping: {
          "misc-24037" => {"repository" => prod.repositories.first.name,
                           "product" => prod.name,
                           "redhat" => prod.redhat?
          }
        },
        content_view_version: {
          major: content_view_version.major,
          minor: content_view_version.minor
        }
      }.with_indifferent_access
    end

    let(:path) do
      "/tmp/foo"
    end

    def setup_proxy
      proxy = FactoryBot.create(:smart_proxy, :default_smart_proxy, :with_pulp3)
      SmartProxy.any_instance.stubs(:pulp_primary).returns(proxy)
      proxy.smart_proxy_features.where(:feature_id => Feature.find_by(:name => SmartProxy::PULP_FEATURE)).delete_all
    end

    before do
      set_user
      SmartProxy.any_instance.stubs(:ping_pulp3).returns({})
      SmartProxy.any_instance.stubs(:pulp3_configuration).returns(nil)
      ::Katello::Pulp3::Api::ContentGuard.any_instance.stubs(:list).returns(nil)
      ::Katello::Pulp3::Api::ContentGuard.any_instance.stubs(:create).returns(nil)
      ::Katello::Repository.any_instance.stubs(:pulp_scratchpad_checksum_type).returns(nil)
    end
  end

  class ImportTest < TestBase
    before do
      setup_proxy
      content_view.import_only = true
    end

    describe 'Import' do
      it 'should fail on importing content for an existing versions' do
        exception = assert_raises(RuntimeError) do
          plan_action(action, content_view, path: path, metadata: metadata)
        end
        assert_match(/'#{content_view_version.name}' already exists/, exception.message)
      end

      it 'should plan properly' do
        metadata[:content_view_version][:major] += 10
        ::Katello::Pulp3::ContentViewVersion::Import.expects(:check!).with(content_view: content_view, metadata: metadata, path: path).returns

        plan_action(action, content_view, path: path, metadata: metadata)
        assert_action_planned_with(action,
                                    ::Actions::Katello::ContentView::Publish,
                                    content_view, '',
                                    path: path,
                                    metadata: metadata,
                                    importing: true,
                                    major: metadata[:content_view_version][:major],
                                    minor: metadata[:content_view_version][:minor])
      end

      it 'should plan the full tree appropriately' do
        ::Katello::Pulp3::ContentViewVersion::Import.expects(:check!).with(content_view: content_view, metadata: metadata, path: path).returns

        metadata[:content_view_version][:major] += 10
        generated_cvv = nil
        tree = plan_action_tree(action_class, content_view, path: path, metadata: metadata)

        assert_empty tree.errors
        assert_tree_planned_steps(tree, Actions::Katello::ContentView::AddToEnvironment)
        assert_tree_planned_steps(tree, Actions::Katello::ContentViewVersion::CreateRepos)
        assert_tree_planned_steps(tree, Actions::Pulp3::Orchestration::ContentViewVersion::Import)
        assert_tree_planned_steps(tree, Actions::Pulp3::Orchestration::ContentViewVersion::CopyVersionUnitsToLibrary)

        assert_tree_planned_with(tree, Actions::Pulp3::ContentViewVersion::CreateImporter) do |input|
          assert_equal SmartProxy.pulp_primary.id, input[:smart_proxy_id]
          assert_equal path, input[:path]
          generated_cvv = ::Katello::ContentViewVersion.find(input[:content_view_version_id])
          assert_equal content_view_version.content_view.id, generated_cvv.content_view.id
          assert_equal metadata[:content_view_version][:major], generated_cvv.major
          assert_equal metadata[:content_view_version][:minor], generated_cvv.minor
        end

        assert_tree_planned_with(tree, Actions::Pulp3::ContentViewVersion::Import) do |input|
          assert_equal SmartProxy.pulp_primary.id, input[:smart_proxy_id]
          assert_equal path, input[:path]
          assert_equal generated_cvv.id, input[:content_view_version_id]
          refute_nil input[:importer_data]
        end
        assert_tree_planned_with(tree, Actions::Pulp3::ContentViewVersion::DestroyImporter)

        assert_tree_planned_with(tree, Actions::Pulp3::Repository::CopyContent) do |input|
          assert input[:copy_all]
          refute input[:mirror]
          refute_nil input[:source_repository_id]
          refute_nil input[:target_repository_id]
          refute_nil input[:smart_proxy_id]
        end
      end
    end
  end
end
