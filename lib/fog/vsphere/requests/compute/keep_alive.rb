#
#   Copyright (c) 2012 VMware, Inc. All Rights Reserved.
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#

module Fog
  module Compute
    class Vsphere

      module Shared
        include Fog::Vsphere::Utility

        def keep_alive
          keep_alive_util(@connection)
        end

      end

      class Real
        include Shared
      end

      class Mock
        include Shared
      end

    end
  end
end
