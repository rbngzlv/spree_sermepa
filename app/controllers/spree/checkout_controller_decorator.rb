module Spree
  Spree::CheckoutController.class_eval do
    before_filter :redirect_to_sermepa_form_if_needed, :only => [:update]

    # Receive a direct notification from the gateway
    def sermepa_notify
      decoded_params = Base64.decode64(params["Ds_MerchantParameters"])
      decoded_hash_params = JSON.parse(decoded_params)
      params.merge!(decoded_hash_params)
      tmp = {}
      params.each{|k,v| tmp[k.downcase] = v}
      params.merge!(tmp)

      notify = ActiveMerchant::Billing::Integrations::Sermepa.notification(params)
      @order ||= Spree::Order.find_by_number! params['order_id']

      notification_log = Spree::RedsysNotification.create({
                            order_id: @order.id,
                            order_amount: @order.total,
                            ds_amount: (params['ds_amount'].to_f / 100),
                            ds_response: params['ds_response'],
                            ds_merchant_parameters: decoded_hash_params.select{ |k,v| k.start_with?('Ds') }.to_yaml
                          })

      http_status = :error # Error status 500 by default
      notify_acknowledge = notify.acknowledge(sermepa_credentials(payment_method))
      if notify_acknowledge and notify.complete? and @order.state != "complete"
        @order.payments.destroy_all
        order_upgrade
        payment_upgrade
        payment = Spree::Payment.find_by_order_id(@order)
        payment.complete!
        http_status = :ok # Everything fine, OK status 200
      else
        @order.payments.destroy_all
        payment = @order.payments.create({:amount => @order.total,
                                           :source_type => 'Spree:SermepaCreditCard',
                                           :payment_method => payment_method,
                                           :state => 'processing',
                                           :response_code => notify.error_code,
                                           :avs_response => notify.error_message[0..255]},
                                          :without_protection => true)
        payment.failure!
        http_status = :ok # We processed the request, OK status 200
      end

      notification_log.update_attributes({response_code: http_status})

      render :nothing => true, :status => http_status
    end

    # Handle the incoming user
    def sermepa_confirm
      load_order
      order_upgrade()
      payment_upgrade()
      redirect_to completion_route
    end

    # create the gateway from the supplied options
    def payment_method
      @payment_method ||= Spree::PaymentMethod.find(params[:payment_method_id])
      @payment_method ||= Spree::PaymentMethod.find_by_type("Spree::BillingIntegration::SermepaPayment")
    end

    private

    def asset_url(_path)
      URI::HTTP.build(:path => ActionController::Base.helpers.asset_path(_path), :host => Spree::Config[:site_url]).to_s
    end


    def redirect_to_sermepa_form_if_needed
      return unless (params[:state] == "payment")
      return unless params[:order][:payments_attributes]

      if @order.update_attributes(object_params)
        if params[:order][:coupon_code] and !params[:order][:coupon_code].blank? and @order.coupon_code.present?
          fire_event('spree.checkout.coupon_code_added', :coupon_code => @order.coupon_code)
        end
      end

      load_order
      @payment_method = Spree::PaymentMethod.find(params[:order][:payments_attributes].first[:payment_method_id])

      if @payment_method.kind_of?(Spree::BillingIntegration::SermepaPayment)

        @payment_method.provider_class::Helper.credentials = sermepa_credentials(payment_method)
        #set_cache_buster
        render 'spree/shared/_sermepa_payment_checkout', :layout => 'spree_sermepa_application'
      end
    end

    def sermepa_credentials (payment_method)
      {
          :terminal_id   => payment_method.preferred_terminal_id,
          :commercial_id => payment_method.preferred_commercial_id,
          :secret_key    => payment_method.preferred_secret_key,
          :key_type      => payment_method.preferred_key_type
      }
    end

    def user_locale
      I18n.locale.to_s
    end

    def sermepa_gateway
      payment_method.provider
    end

    def set_cache_buster
      response.headers["Cache-Control"] = "no-cache, no-store" #post-check=0, pre-check=0
      response.headers["Pragma"] = "no-cache"
      response.headers["Expires"] = "Fri, 01 Jan 1990 00:00:00 GMT"
    end

    def order_upgrade
      ## TODO refactor coz u don't need really @order.state = "payment"
      @order.state = "payment"
      @order.save

      @order.update_attributes({:state => "complete", :completed_at => Time.now}, :without_protection => true)

      state_callback(:after) # So that after_complete is called, setting session[:order_id] to nil

      # Since we dont rely on state machine callback, we just explicitly call this method for spree_store_credits
      if @order.respond_to?(:consume_users_credit, true)
        @order.send(:consume_users_credit)
      end

      @order.finalize!
    end

    def payment_upgrade
      #payment_method = Spree::PaymentMethod.find_by_type("Spree::BillingIntegration::SermepaPayment")
      payment = @order.payments.create({:amount => @order.total,
                                        :source_type => 'Spree:SermepaCreditCard',
                                        :payment_method => payment_method },
                                        :without_protection => true)
      payment.started_processing!
      payment.pend!
    end

  end

end
