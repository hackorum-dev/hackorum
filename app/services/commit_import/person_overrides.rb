module CommitImport
  # Trailer people misspelled in the commit message itself. Valid but unknown
  # addresses and names written in another order or without accents resolve
  # on their own, so only real typos go here.
  #
  # Keys are lowercased, as the parser and the resolver hand them over.
  # Values are an address of the intended person. Only add a pair after
  # confirming that address resolves to the right person; a wrong guess
  # silently credits someone else.
  module PersonOverrides
    EMAILS = {
      "andres@andres@anarazel.de" => "andres@anarazel.de",
      "a.yhalov@postgrespro.ru" => "a.pyhalov@postgrespro.ru",
      "daniel@yesql.sea" => "daniel@yesql.se",
      "drowleyml@gmail.com" => "dgrowleyml@gmail.com",
      "horikyoga.ntt@gmail.com" => "horikyota.ntt@gmail.com",
      "horikyotajntt@gmail.com" => "horikyota.ntt@gmail.com",
      "pbh.emaj@free.fr" => "phb.emaj@free.fr",
      "sanmimseih@gmail.com" => "samimseih@gmail.com",
      "simon@2ndqudrant.com" => "simon@2ndquadrant.com"
    }.freeze

    NAMES = {
      "alexander korortkov" => "aekorotkov@gmail.com",
      "alexandex korotkov" => "aekorotkov@gmail.com",
      "amit kamila" => "amit.kapila16@gmail.com",
      "amita kapila" => "amit.kapila16@gmail.com",
      "anit kapila" => "amit.kapila16@gmail.com",
      "daniel dustafsson" => "daniel@yesql.se",
      "daniel gustaffson" => "daniel@yesql.se",
      "dave crammer" => "pg@fastcrypt.com",
      "david steel" => "david@pgmasters.net",
      "dimitri dolgov" => "9erthalion6@gmail.com",
      "fabian coelho" => "coelho@cri.ensmp.fr",
      "jelte fenema-nio" => "postgres@jeltef.nl",
      "julien rohaud" => "rjuju123@gmail.com",
      "justin prysby" => "pryzby@telsasoft.com",
      "khuntal ghosh" => "kuntalghosh.2007@gmail.com",
      "kyatoro horiguchi" => "horikyota.ntt@gmail.com",
      "kyptaro horiguchi" => "horikyota.ntt@gmail.com",
      "lukas fitti" => "lukas@fittl.com",
      "masahiho sawada" => "sawada.mshk@gmail.com",
      "masahiko sawasa" => "sawada.mshk@gmail.com",
      "nazir bilal yavuzk" => "byavuz81@gmail.com",
      "nikita gluknov" => "n.gluhov@postgrespro.ru",
      "nikolay sharplov" => "dhyan@nataraj.su",
      "oleg samoilov" => "splarv@ya.ru",
      "peter eisentraunt" => "peter_e@gmx.net",
      "robert hass" => "robertmhaas@gmail.com",
      "seigei kornilov" => "sk@zsrv.org",
      "shveta mallik" => "shveta.malik@gmail.com",
      "stas kelvish" => "s.kelvich@postgrespro.ru",
      "tatsuro ishii" => "ishii@postgresql.org",
      "yan chengpen" => "chengpeng_yan@outlook.com"
    }.freeze

    def self.email_for(raw_email, raw_name)
      email = raw_email.presence&.downcase
      return EMAILS.fetch(email, email) if email

      NAMES[raw_name.to_s.downcase.squeeze(" ").strip]
    end
  end
end
