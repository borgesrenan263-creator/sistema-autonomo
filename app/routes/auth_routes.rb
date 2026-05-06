get "/login" do
  @page = "login"
  erb :login, layout: false
end

post "/login" do
  username = params[:username].to_s
  password = params[:password].to_s

  if valid_admin_login?(username, password)
    session[:admin_logged_in] = true
    session[:admin_username] = username
    redirect "/"
  else
    @error = "Login inválido."
    erb :login, layout: false
  end
end

post "/logout" do
  session.clear
  redirect "/login"
end
