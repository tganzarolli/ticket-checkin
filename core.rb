require 'sinatra'
require 'json'
require 'open-uri'
require 'hpricot'
require 'expense'
require 'oauth'
require 'couchrest'
require 'utils'
require 'accor_ticket'
require 'visa_ticket'
require 'base64'
require 'hmac-sha1'
include Utils

#monkey_patch para put. Melhor colocar em classe externa

module OAuth::RequestProxy::Net
  module HTTP
    class HTTPRequest < OAuth::RequestProxy::Base
      def query_string
        params = [ query_params, auth_header_params ]
        params << post_params if
          ['POST', 'PUT'].include?(method.to_s.upcase)
        params.compact.join('&')
      end
    end
  end
end

enable :sessions 

get '/ticket_history/:card_number' do
  number = params[:card_number]
  expense_array = get_expenses number
  #haml :history
  #expense_array[0]
  expense_array.to_json
end

get '/' do
  @consumer_key = ApontadorConfig.get_map['consumer_key']
  @callback_login = redirect_uri('/apontador_login_callback')
  haml :signup
end

post '/process_signup' do
  redirect '/' unless params[:card_number].length > 0
  session[:card_number] = params[:card_number].delete(' ')
  session[:card_type] = params[:card_type]
  request_token=client(:scheme => :query_string).get_request_token(:oauth_callback => redirect_uri)
  redirect request_token.authorize_url
end

get '/apontador_callback' do
  access_token=client(:scheme => :query_string).get_access_token(nil,:oauth_callback => redirect_uri, :oauth_verifier => params[:oauth_verifier])
  puts access_token.token
  puts access_token.secret
  response = access_token.get("http://#{ApontadorConfig.get_map['api_host']}/#{ApontadorConfig.get_map['api_sufix']}/users/self?type=json",{ 'Accept'=>'application/json' })
  user = JSON.parse(response.body)
  @db = get_db
  begin
    @mensagem = "#{user['user']['name']}, você acaba de registar seu vale/ticket da #{session[:card_type].capitalize} de número #{session[:card_number]} no sanduicheck.in. Agora é só usar o"
    @mensagem = @mensagem + " seu cartão e aguardar o check-in automático em seguida. Você pode retornar ao site e se logar para ver seu histórico e outras opções."
    @db.save_doc({'_id' => user['user']['id'], :type => 'user', :name => user['user']['name'], "#{session[:card_type]}_ticket".to_sym => session[:card_number], 
      :access_token => access_token.token, :access_secret => access_token.secret})
  rescue RestClient::Conflict => conflic
    doc = @db.get(user['user']['id'])
    doc['access_token'] = access_token.token
    doc['access_secret'] = access_token.secret
    doc["#{session[:card_type]}_ticket"] = session[:card_number]
    @db.save_doc(doc)
    @mensagem = "#{user['user']['name']}, você já havia registrado um ticket conosco. Ele acaba de ser atualizado para o vale/ticket da #{session[:card_type].capitalize} de número #{session[:card_number]} no sanduicheck.in."
  end
  haml :success
end

get '/apontador_login_callback' do
  
  encoder = HMAC::SHA1.new(ApontadorConfig.get_map['consumer_secret'])
  
  username = params[:name]
  userid = params[:userid]
  token = params[:token]
  
  signature_base = "consumerkey=#{params[:consumerkey]}&name=#{username}&token=#{token}&url=#{params[:url]}&userid=#{userid}"
  mysignature = Base64.encode64((encoder << signature_base).digest).strip
  raise Exception "Assinatura inválida" unless mysignature == params[:signature]
  
  timestamp = Time.now.to_i
  signature_check_base = "key=#{ApontadorConfig.get_map['consumer_key']}&token=#{token}&ts=#{timestamp}&userid=#{userid}"
  signature_check = Base64.encode64((encoder << signature_check_base).digest).strip
  path_check = "/check?token=#{token}&userid=#{userid}&ts=#{timestamp}&key=#{ApontadorConfig.get_map['consumer_key']}&signature=#{signature_check}"
  url_check = 'http://'+ ApontadorConfig.get_map['auth_host'] + path_check
  begin 
    f = open(url_check)
    check_map = JSON.parse(f.read.gsub("'", "\""))
    #se for trusted terei email, token, token_secret adicionais
    #puts check_map['token_secret']
    check_map['name'] + '|' + check_map['userid']
  rescue Exception => e
    puts e
  end

end

def checkin_all
  @db = get_db
  @db.view('users/all')['rows'].each do |row|
    user = row['value']
    puts user['name']
    checkin user
  end
end

private

  def client(params={})
    OAuth::Consumer.new(ApontadorConfig.get_map['consumer_key'],ApontadorConfig.get_map['consumer_secret'], {
        :site => 'http://' + ApontadorConfig.get_map['api_host'], :http_method => :get, :request_token_path => "/#{ApontadorConfig.get_map['api_sufix']}/oauth/request_token", :authorize_path => "/#{ApontadorConfig.get_map['api_sufix']}/oauth/authorize", :access_token_path => "/#{ApontadorConfig.get_map['api_sufix']}/oauth/access_token"
        }.merge(params))
  end

  def get_db
    couchdb_config = CouchDBConfig.get_map
    @db = CouchRest.database!("http://#{couchdb_config['user']}:#{couchdb_config['password']}@#{couchdb_config['host']}/#{couchdb_config['database']}")
  end

  
  def redirect_uri(path=nil)
    uri = URI.parse(request.url)
    uri.path = path || '/apontador_callback'
    uri.query = nil
    uri.to_s
  end
  
  def checkin user
    #@db = get_db
    #troque para testar. 0 para prod
    offset = 0
    ticket_number = user['accor_ticket'] || user['visa_ticket']
    brand = (user['accor_ticket']) ? 'Accor' : 'Visa'
    manager = Kernel.const_get "#{brand.capitalize}ExpensesManager"
    expense_array = manager.get_expenses ticket_number, lambda{ |expense| build_date(expense.date) == (Date.today - offset)}
    puts expense_array.length
    expense_array.each do |expense|
      expense_hash = JSON.parse(expense.to_json)['expense']
      begin
        if @db.view('unique_expenses/by_date_amount_and_desc', {'key' => [expense.date,expense.amount,expense.description]})['rows'].length == 0
          puts expense.to_json
          place_id = find_place expense.description
          if not place_id
            puts 'Não encontrado' + expense.description
            #TODO parametrizar multiplas cidades e estados
            synonyms = @db.view('synonyms/by_name_and_region', {'key' => [expense.description,'SP','São Paulo']})['rows']
            place_id = find_place synonyms.first['value']['synonym'] unless synonyms.empty?
          end
          if place_id
            perform_checkin(user, place_id)
            @db.save_doc(expense_hash.merge(:type => 'expense', :ticket => ticket_number))  
          end
        end
      rescue Exception => e
        puts e
      end
    end
  end
  
  def find_place term
    #busca restaurante
    place_id = find_place_category term, 67
    #senao tenta lanchonete
    place_id ||= find_place_category term, 3 
  end
  
  def find_place_category term, category
    term = URI.escape term
    url = "http://#{ApontadorConfig.get_map['api_host']}/#{ApontadorConfig.get_map['api_sufix']}/search/places/byaddress?term=#{term}&state=sp&city=s%C3%A3o%20paulo&category_id=#{category}&type=json"
    f = open(url, :http_basic_authentication => [ApontadorConfig.get_map['consumer_key'], ApontadorConfig.get_map['consumer_secret']])
    obj = JSON.parse f.read
    if (obj['search']['result_count'].to_i > 0 )
      place_id = obj['search']['places'][0]['place']['id'].to_s
    end
  end
  
  def perform_checkin(user, place_id)
    access_token = OAuth::AccessToken.new(client(:scheme => :body, :method => :put), user['access_token'], user['access_secret'])
    response = access_token.put("http://#{ApontadorConfig.get_map['api_host']}/#{ApontadorConfig.get_map['api_sufix']}/users/self/visits",{:type => 'json', :place_id => place_id}, {'Accept'=>'application/json' })
    result = JSON.parse(response.body)
  end
  