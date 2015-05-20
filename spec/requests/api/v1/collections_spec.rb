require 'rails_helper'

describe API::V1::Collections do
  let(:valid_session) do
    yaml = YAML.load_file("#{Rails.root}/config/secrets.yml")
    env_secrets = yaml[Rails.env]
    credentials = ActionController::HttpAuthentication::Basic.encode_credentials env_secrets['admin_user'], env_secrets['admin_password']
    { 'HTTP_AUTHORIZATION' => credentials }
  end

  describe "POST /api/v1/collections" do
    context 'success case' do
      before do
        Elasticsearch::Persistence.client.delete_by_query index: Collection.index_name, q: '*:*'
        valid_params = { "handle" => "agency_blogs", "token" => "secret" }
        post "/api/v1/collections", valid_params, valid_session
      end

      it 'returns success message as JSON' do
        expect(response.status).to eq(201)
        expect(JSON.parse(response.body)).to match(hash_including('status' => 200, "developer_message" => "OK", "user_message" => "Your collection was successfully created."))
      end

      it 'uses the collection handle as the Elasticsearch ID' do
        expect(Collection.find("agency_blogs")).to be_present
      end

      it 'stores the appropriate fields in the Elasticsearch collection' do
        collection = Collection.find("agency_blogs")
        expect(collection.token).to eq("secret")
      end
    end

    context 'a required parameter is empty/blank' do
      before do
        invalid_params = {}
        post "/api/v1/collections", invalid_params, valid_session
      end

      it 'returns failure message as JSON' do
        expect(response.status).to eq(400)
        expect(JSON.parse(response.body)).to match(hash_including('status' => 400, "developer_message" => "handle is missing, handle is empty, handle is invalid, token is missing, token is empty"))
      end
    end

    context 'handle uses illegal characters' do
      before do
        invalid_params = { "handle" => "agency-blogs", "token" => "secret" }
        post "/api/v1/collections", invalid_params, valid_session
      end

      it 'returns failure message as JSON' do
        expect(response.status).to eq(400)
        expect(JSON.parse(response.body)).to match(hash_including('status' => 400, "developer_message" => "handle is invalid"))
      end
    end

    context 'failed authentication/authorization' do
      before do
        valid_params = { "handle" => "agency_blogs", "token" => "secret" }
        bad_credentials = ActionController::HttpAuthentication::Basic.encode_credentials "nope", "wrong"

        valid_session = { 'HTTP_AUTHORIZATION' => bad_credentials }
        post "/api/v1/collections", valid_params, valid_session
      end

      it 'returns error message as JSON' do
        expect(response.status).to eq(400)
        expect(JSON.parse(response.body)).to match(hash_including('status' => 400, "developer_message" => "Unauthorized"))
      end
    end

    context 'something terrible happens' do
      before do
        allow(Collection).to receive(:create) { raise_error(Exception) }
        valid_params = { "handle" => "agency_blogs", "token" => "secret" }
        post "/api/v1/collections", valid_params, valid_session
      end

      it 'returns failure message as JSON' do
        expect(response.status).to eq(500)
        expect(JSON.parse(response.body)).to match(hash_including('status' => 500, "developer_message" => "Something unexpected happened and we've been alerted."))
      end
    end

  end

  describe "DELETE /api/v1/collections/{handle}" do
    context 'success case' do
      before do
        Elasticsearch::Persistence.client.delete_by_query index: Collection.index_name, q: '*:*'
        Collection.create(_id: "agency_blogs", token: "secret")
        delete "/api/v1/collections/agency_blogs", nil, valid_session
      end

      it 'returns success message as JSON' do
        expect(response.status).to eq(200)
        expect(JSON.parse(response.body)).to match(hash_including('status' => 200, "developer_message" => "OK", "user_message" => "Your collection was successfully deleted."))
      end

      it 'deletes the collection' do
        expect(Collection.exists?("agency_blogs")).to be_falsey
      end

    end
  end

  describe "GET /api/v1/collections/search" do
    context 'success case' do
      before do
        Elasticsearch::Persistence.client.delete_by_query index: Collection.index_name, q: '*:*'
        valid_params = { "handle" => "agency_blogs", "token" => "secret" }
        post "/api/v1/collections", valid_params, valid_session
        Document.index_name = Document.index_namespace('agency_blogs')
        Elasticsearch::Persistence.client.delete_by_query index: Document.index_name, q: '*:*'
      end

      let(:datetime) { DateTime.now.utc }
      let(:hash1) { { _id: 'a1', language: 'en', title: 'title 1 common content', description: 'description 1 common content', content: 'content 1 common content', created: datetime.to_s, path: 'http://www.agency.gov/page1.html', promote: false, updated: datetime.to_s } }
      let(:hash2) { { _id: 'a2', language: 'en', title: 'title 2 common content', description: 'description 2 common content', content: 'other unrelated stuff', created: datetime.to_s, path: 'http://www.agency.gov/page2.html', promote: true } }

      it 'returns highlighted JSON search results' do
        Document.create(hash1)
        Document.create(hash2)
        Document.refresh_index!
        valid_params = { 'language' => 'en', 'query' => 'common content', 'handles' => 'agency_blogs' }
        get "/api/v1/collections/search", valid_params, valid_session
        expect(response.status).to eq(200)
        metadata_hash = { 'total' => 2, 'offset' => 0 }
        result1 = { "language" => "en", "created" => datetime.to_s, "path" => 'http://www.agency.gov/page1.html', "promote" => false, "updated" => datetime.to_s, "title" => 'title 1 common content', "description" => 'description 1 common content', "content" => 'content 1 common content' }
        result2 = { "language" => "en", "created" => datetime.to_s, "path" => 'http://www.agency.gov/page2.html', "promote" => true, "title" => 'title 2 common content', "description" => 'description 2 common content', "content" => 'other unrelated stuff'  }
        results_array = [result1, result2]
        expect(JSON.parse(response.body)).to match(hash_including('status' => 200, "developer_message" => "OK", "metadata" => metadata_hash, 'results' => results_array))
      end
    end

    context 'no results' do
      before do
        Elasticsearch::Persistence.client.delete_by_query index: Collection.index_name, q: '*:*'
        valid_params = { "handle" => "agency_blogs", "token" => "secret" }
        post "/api/v1/collections", valid_params, valid_session
        Document.index_name = Document.index_namespace('agency_blogs')
        Elasticsearch::Persistence.client.delete_by_query index: Document.index_name, q: '*:*'
      end

      it 'returns JSON no hits results' do
        valid_params = { 'language' => 'en', 'query' => 'no hits', 'handles' => 'agency_blogs' }
        get "/api/v1/collections/search", valid_params, valid_session
        expect(response.status).to eq(200)
        metadata_hash = { 'total' => 0, 'offset' => 0 }
        results_array = []
        expect(JSON.parse(response.body)).to match(hash_including('status' => 200, "developer_message" => "OK", "metadata" => metadata_hash, 'results' => results_array))
      end

    end

    context 'missing required params' do
      before do
        invalid_params = {}
        get "/api/v1/collections/search", invalid_params, valid_session
      end

      it 'returns error message as JSON' do
        expect(response.status).to eq(400)
        expect(JSON.parse(response.body)).to match(hash_including('status' => 400, "developer_message" => "handles is missing, handles is empty, language is missing, language does not have a valid value, language is empty, query is missing, query is empty"))
      end
    end

    context 'searching across one or more collection handles that do not exist' do
      before do
        Elasticsearch::Persistence.client.delete_by_query index: Collection.index_name, q: '*:*'
        Collection.create(_id: "agency_blogs", token: "secret")
        bad_handle_params = { 'language' => 'en', 'query' => 'foo', 'handles' => 'agency_blogs,missing' }
        get "/api/v1/collections/search", bad_handle_params, valid_session
      end

      it 'returns error message as JSON' do
        expect(response.status).to eq(400)
        expect(JSON.parse(response.body)).to match(hash_including("error" => "Could not find all the specified collection handles"))
      end
    end
  end
end