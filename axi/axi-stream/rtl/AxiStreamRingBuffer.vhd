-------------------------------------------------------------------------------
-- Company    : SLAC National Accelerator Laboratory
-------------------------------------------------------------------------------
-- Description: Wrapper for simple BRAM based ring buffer with AXI Stream interface
-------------------------------------------------------------------------------
-- This file is part of 'SLAC Firmware Standard Library'.
-- It is subject to the license terms in the LICENSE.txt file found in the
-- top-level directory of this distribution and at:
--    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html.
-- No part of 'SLAC Firmware Standard Library', including this file,
-- may be copied, modified, propagated, or distributed except according to
-- the terms contained in the LICENSE.txt file.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

library surf;
use surf.StdRtlPkg.all;
use surf.AxiStreamPkg.all;
use surf.AxiLitePkg.all;
use surf.SsiPkg.all;

entity AxiStreamRingBuffer is
   generic (
      TPD_G               : time     := 1 ns;
      SYNTH_MODE_G        : string   := "inferred";
      MEMORY_TYPE_G       : string   := "block";
      DATA_BYTES_G        : positive := 16;
      RAM_ADDR_WIDTH_G    : positive := 9;
      -- AXI Stream Configurations
      INT_PIPE_STAGES_G   : natural  := 1;
      PIPE_STAGES_G       : natural  := 1;
      GEN_SYNC_FIFO_G     : boolean  := false;
      FIFO_MEMORY_TYPE_G  : string   := "block";
      FIFO_ADDR_WIDTH_G   : positive := 9;
      AXI_STREAM_CONFIG_G : AxiStreamConfigType);
   port (
      -- Data to store in ring buffer (dataClk domain)
      dataClk         : in  sl;
      dataRst         : in  sl := '0';
      dataValid       : in  sl := '1';
      dataValue       : in  slv(8*DATA_BYTES_G-1 downto 0);
      bufferEnable    : in  sl := '0';
      bufferClear     : in  sl := '0';
      -- AXI-Lite interface (axilClk domain)
      axilClk         : in  sl;
      axilRst         : in  sl;
      axilReadMaster  : in  AxiLiteReadMasterType;
      axilReadSlave   : out AxiLiteReadSlaveType;
      axilWriteMaster : in  AxiLiteWriteMasterType;
      axilWriteSlave  : out AxiLiteWriteSlaveType;
      -- AXI-Stream Interface (axisClk domain)
      axisClk         : in  sl;
      axisRst         : in  sl;
      axisMaster      : out AxiStreamMasterType;
      axisSlave       : in  AxiStreamSlaveType);
end AxiStreamRingBuffer;

architecture rtl of AxiStreamRingBuffer is

   constant AXIS_CONFIG_C : AxiStreamConfigType := ssiAxiStreamConfig(
      dataBytes => DATA_BYTES_G,
      tKeepMode => TKEEP_FIXED_C,
      tUserMode => TUSER_FIRST_LAST_C,
      tDestBits => 0,
      tUserBits => 2,
      tIdBits   => 0);

   ------------------------------
   -- Stream clock domain signals
   ------------------------------
   type DataRegType is record
      enable       : sl;
      cleared      : sl;
      armed        : sl;
      ramWrEn      : sl;
      readReq      : sl;
      ramWrData    : slv(8*DATA_BYTES_G-1 downto 0);
      bufferLength : slv(RAM_ADDR_WIDTH_G-1 downto 0);
      firstAddr    : slv(RAM_ADDR_WIDTH_G-1 downto 0);
      nextAddr     : slv(RAM_ADDR_WIDTH_G-1 downto 0);
   end record;

   constant DATA_REG_INIT_C : DataRegType := (
      enable       => '0',
      cleared      => '1',              -- Only set HIGH after reset
      armed        => '0',
      ramWrEn      => '0',
      readReq      => '0',
      ramWrData    => (others => '0'),
      bufferLength => (others => '0'),
      firstAddr    => (others => '0'),
      nextAddr     => (others => '0'));

   signal dataR   : DataRegType := DATA_REG_INIT_C;
   signal dataRin : DataRegType;

   signal bufferEnableSync : sl;
   signal bufferClearSync  : sl;

   --------------------------------
   -- AXI-Lite clock domain signals
   --------------------------------
   type DataStateType is (
      IDLE_S,
      MOVE_S);

   type TrigStateType is (
      IDLE_S,
      CLEAR_S,
      ARMED_S,
      WAIT_S);

   type AxilRegType is record
      trigCnt        : slv(31 downto 0);
      continuous     : sl;
      bufferEnable   : sl;
      bufferClear    : sl;
      wordCnt        : slv(RAM_ADDR_WIDTH_G-1 downto 0);
      ramRdAddr      : slv(RAM_ADDR_WIDTH_G-1 downto 0);
      rdEn           : slv(2 downto 0);
      axilReadSlave  : AxiLiteReadSlaveType;
      axilWriteSlave : AxiLiteWriteSlaveType;
      txMaster       : AxiStreamMasterType;
      dataState      : DataStateType;
      trigState      : TrigStateType;
   end record;

   constant AXIL_REG_INIT_C : AxilRegType := (
      trigCnt        => (others => '0'),
      continuous     => '0',
      bufferEnable   => '0',
      bufferClear    => '0',
      wordCnt        => (others => '0'),
      ramRdAddr      => (others => '0'),
      rdEn           => "000",
      axilReadSlave  => AXI_LITE_READ_SLAVE_INIT_C,
      axilWriteSlave => AXI_LITE_WRITE_SLAVE_INIT_C,
      txMaster       => axiStreamMasterInit(AXIS_CONFIG_C),
      dataState      => IDLE_S,
      trigState      => IDLE_S);

   signal axilR   : AxilRegType := AXIL_REG_INIT_C;
   signal axilRin : AxilRegType;

   signal ramRdData    : slv(8*DATA_BYTES_G-1 downto 0);
   signal firstAddr    : slv(RAM_ADDR_WIDTH_G-1 downto 0);
   signal bufferLength : slv(RAM_ADDR_WIDTH_G-1 downto 0);

   signal extBufferEnable : sl;
   signal extBufferClear  : sl;
   signal readReq         : sl;
   signal cleared         : sl;
   signal armed           : sl;

   signal txSlave : AxiStreamSlaveType;

begin

   ----------------------
   -- Instantiate the RAM
   ----------------------
   GEN_XPM : if (SYNTH_MODE_G = "xpm") generate
      U_Ram : entity surf.SimpleDualPortRamXpm
         generic map (
            TPD_G          => TPD_G,
            MEMORY_TYPE_G  => MEMORY_TYPE_G,
            READ_LATENCY_G => 2,
            DATA_WIDTH_G   => 8*DATA_BYTES_G,
            ADDR_WIDTH_G   => RAM_ADDR_WIDTH_G)
         port map (
            -- Port A
            clka   => dataClk,
            wea(0) => dataR.ramWrEn,
            addra  => dataR.nextAddr,
            dina   => dataR.ramWrData,
            -- Port B
            clkb   => axilClk,
            rstb   => axilRst,
            addrb  => axilR.ramRdAddr,
            doutb  => ramRdData);
   end generate;

   GEN_ALTERA : if (SYNTH_MODE_G = "altera_mf") generate
      U_Ram : entity surf.SimpleDualPortRamAlteraMf
         generic map (
            TPD_G          => TPD_G,
            MEMORY_TYPE_G  => MEMORY_TYPE_G,
            READ_LATENCY_G => 2,
            DATA_WIDTH_G   => 8*DATA_BYTES_G,
            ADDR_WIDTH_G   => RAM_ADDR_WIDTH_G)
         port map (
            -- Port A
            clka   => dataClk,
            wea(0) => dataR.ramWrEn,
            addra  => dataR.nextAddr,
            dina   => dataR.ramWrData,
            -- Port B
            clkb   => axilClk,
            rstb   => axilRst,
            addrb  => axilR.ramRdAddr,
            doutb  => ramRdData);
   end generate;

   GEN_INFERRED : if (SYNTH_MODE_G = "inferred") generate
      U_Ram : entity surf.SimpleDualPortRam
         generic map (
            TPD_G         => TPD_G,
            MEMORY_TYPE_G => MEMORY_TYPE_G,
            DOB_REG_G     => true,
            DATA_WIDTH_G  => 8*DATA_BYTES_G,
            ADDR_WIDTH_G  => RAM_ADDR_WIDTH_G)
         port map (
            -- Port A
            clka  => dataClk,
            wea   => dataR.ramWrEn,
            addra => dataR.nextAddr,
            dina  => dataR.ramWrData,
            -- Port B
            clkb  => axilClk,
            rstb  => axilRst,
            addrb => axilR.ramRdAddr,
            doutb => ramRdData);
   end generate;

   --------------------------------------------------
   -- Synchronize AXI registers to data clock dataClk
   --------------------------------------------------
   U_SyncVec_dataClk : entity surf.SynchronizerVector
      generic map (
         TPD_G   => TPD_G,
         WIDTH_G => 2)
      port map (
         clk        => dataClk,
         rst        => dataRst,
         dataIn(0)  => axilR.bufferEnable,
         dataIn(1)  => axilR.bufferClear,
         dataOut(0) => bufferEnableSync,
         dataOut(1) => bufferClearSync);

   --------------------------
   -- Main AXI-Stream process
   --------------------------
   dataComb : process (bufferClear, bufferClearSync, bufferEnable,
                       bufferEnableSync, dataR, dataRst, dataValid, dataValue) is
      variable v : DataRegType;
   begin
      -- Latch the current value
      v := dataR;

      -- Reset strobes
      v.ramWrEn := '0';
      v.readReq := '0';
      v.cleared := '0';

      -- Default assignment
      v.ramWrData := dataValue;
      v.enable    := bufferEnableSync or bufferEnable;

      -- Increment the addresses on each valid if logging enabled
      if (dataValid = '1') and (dataR.enable = '1') then
         -- Trigger a write
         v.ramWrEn := '1';

         -- Increment the address
         v.nextAddr := dataR.nextAddr + 1;
         -- Check if the write pointer = read pointer
         if (v.nextAddr = dataR.firstAddr) then
            v.firstAddr := dataR.firstAddr + 1;
            v.armed     := '1';
         end if;
         -- Calculate the length of the buffer
         v.bufferLength := dataR.nextAddr - dataR.firstAddr;
      end if;

      -- Check for read request event
      if (dataR.enable = '1') and (v.enable = '0') then
         v.readReq := '1';
      end if;

      -- Synchronous Reset
      if (dataRst = '1') or (bufferClearSync = '1') or (bufferClear = '1') then
         v := DATA_REG_INIT_C;
      end if;

      -- Register the variable for next clock cycle
      dataRin <= v;

   end process;

   dataSeq : process (dataClk) is
   begin
      if rising_edge(dataClk) then
         dataR <= dataRin after TPD_G;
      end if;
   end process;

   -----------------------------------------------------
   -- Synchronize write address across to AXI-Lite clock
   -----------------------------------------------------
   U_Sync_ReadReq : entity surf.SynchronizerFifo
      generic map (
         TPD_G        => TPD_G,
         DATA_WIDTH_G => 2*RAM_ADDR_WIDTH_G)
      port map (
         rst                                                  => axilRst,
         -- Write Interface
         wr_clk                                               => dataClk,
         wr_en                                                => dataR.readReq,
         din(1*RAM_ADDR_WIDTH_G-1 downto 0*RAM_ADDR_WIDTH_G)  => dataR.firstAddr,
         din(2*RAM_ADDR_WIDTH_G-1 downto 1*RAM_ADDR_WIDTH_G)  => dataR.bufferLength,
         -- Read interface
         rd_clk                                               => axilClk,
         valid                                                => readReq,
         dout(1*RAM_ADDR_WIDTH_G-1 downto 0*RAM_ADDR_WIDTH_G) => firstAddr,
         dout(2*RAM_ADDR_WIDTH_G-1 downto 1*RAM_ADDR_WIDTH_G) => bufferLength);

   U_SyncVec_axilClk : entity surf.SynchronizerVector
      generic map (
         TPD_G   => TPD_G,
         WIDTH_G => 4)
      port map (
         clk        => axilClk,
         rst        => axilRst,
         dataIn(0)  => bufferEnable,
         dataIn(1)  => bufferClear,
         dataIn(2)  => dataR.cleared,
         dataIn(3)  => dataR.armed,
         dataOut(0) => extBufferEnable,
         dataOut(1) => extbufferClear,
         dataOut(2) => cleared,
         dataOut(3) => armed);

   ------------------------
   -- Main AXI-Lite process
   ------------------------
   axiComb : process (armed, axilR, axilReadMaster, axilRst, axilWriteMaster,
                      bufferLength, cleared, extBufferClear, extBufferEnable,
                      firstAddr, ramRdData, readReq, txSlave) is
      variable v      : AxilRegType;
      variable axilEp : AxiLiteEndpointType;
   begin
      -- Latch the current value
      v := axilR;

      ------------------------
      -- AXI-Lite Transactions
      ------------------------

      -- Determine the transaction type
      axiSlaveWaitTxn(axilEp, axilWriteMaster, axilReadMaster, v.axilWriteSlave, v.axilReadSlave);

      axiSlaveRegisterR(axilEp, x"0", 0, bufferLength);
      axiSlaveRegisterR(axilEp, x"0", 20, toSlv(RAM_ADDR_WIDTH_G, 8));
      axiSlaveRegisterR(axilEp, x"0", 28, extBufferClear);
      axiSlaveRegisterR(axilEp, x"0", 29, extBufferEnable);
      axiSlaveRegisterR(axilEp, x"4", 0, axilR.trigCnt);

      axiSlaveRegister (axilEp, x"8", 0, v.trigCnt);
      axiSlaveRegister (axilEp, x"C", 0, v.continuous);

      -- Close the transaction
      axiSlaveDefault(axilEp, v.axilWriteSlave, v.axilReadSlave, AXI_RESP_DECERR_C);

      ------------------------
      -- Local Trigger Logic
      ------------------------

      case axilR.trigState is
         ----------------------------------------------------------------------
         when IDLE_S =>
            -- Check for trigger request
            if (axilR.trigCnt /= 0) or (axilR.continuous = '1') then
               -- Set the flags
               v.bufferClear  := '1';
               v.bufferEnable := '1';
               -- Check if we need to decrement the counter
               if (axilR.trigCnt /= 0) then
                  -- Decrement the counter
                  v.trigCnt := axilR.trigCnt - 1;
               end if;
               -- Next state
               v.trigState := CLEAR_S;
            else
               -- Reset the flags
               v.bufferClear  := '0';
               v.bufferEnable := '0';
            end if;
         ----------------------------------------------------------------------
         when CLEAR_S =>
            -- Check if cleared
            if (cleared = '1') then
               -- Set the flags
               v.bufferClear  := '0';
               v.bufferEnable := '1';
               -- Next state
               v.trigState    := ARMED_S;
            end if;
         ----------------------------------------------------------------------
         when ARMED_S =>
            -- Check if armed
            if (armed = '1') then
               -- Set the flags
               v.bufferClear  := '0';
               v.bufferEnable := '0';
               -- Next state
               v.trigState    := WAIT_S;
            end if;
         ----------------------------------------------------------------------
         when WAIT_S =>
            -- Set the flags
            v.bufferClear  := '0';
            v.bufferEnable := '0';
      ----------------------------------------------------------------------
      end case;

      ------------------------
      -- AXI-Stream
      ------------------------

      -- Update Shift Register
      v.rdEn(0) := '0';
      v.rdEn(1) := axilR.rdEn(0);
      v.rdEn(2) := axilR.rdEn(1);

      -- AXI Stream Flow Control
      if (txSlave.tReady = '1') then
         v.txMaster := axiStreamMasterInit(AXIS_CONFIG_C);
      end if;

      case axilR.dataState is
         ----------------------------------------------------------------------
         when IDLE_S =>
            -- Reset the counter
            v.wordCnt := (others => '0');

            -- Check for trigger event
            if (readReq = '1') then

               -- Next state
               v.dataState := MOVE_S;

            end if;
         ----------------------------------------------------------------------
         when MOVE_S =>
            -- Check if ready to move data
            if (v.txMaster.tValid = '0') and (axilR.rdEn = 0) then

               -- Send the data
               v.txMaster.tValid                           := '1';
               v.txMaster.tData(8*DATA_BYTES_G-1 downto 0) := ramRdData;

               -- Check for Start Of Frame (SOF)
               if (axilR.wordCnt = 0) then

                  -- Set the SOF bit
                  ssiSetUserSof(AXIS_CONFIG_C, v.txMaster, '1');

               end if;

               -- Check for End of Frame (EOF)
               if (axilR.wordCnt = bufferLength) then

                  -- Set the EOF bit
                  v.txMaster.tLast := '1';

                  -- Next states
                  v.dataState := IDLE_S;
                  v.trigState := IDLE_S;

               else
                  -- Increment the counter
                  v.wordCnt := axilR.wordCnt + 1;
               end if;

            end if;
      ----------------------------------------------------------------------
      end case;

      -- Update RAM read address
      v.ramRdAddr := firstAddr + v.wordCnt;

      -- Check for change in address
      if (axilR.ramRdAddr /= v.ramRdAddr) then
         v.rdEn(0) := '1';
      end if;

      -- Outputs
      axilReadSlave  <= axilR.axilReadSlave;
      axilWriteSlave <= axilR.axilWriteSlave;

      -- Synchronous Reset
      if (axilRst = '1') then
         v := AXIL_REG_INIT_C;
      end if;

      -- Register the variable for next clock cycle
      axilRin <= v;

   end process;

   axiSeq : process (axilClk) is
   begin
      if rising_edge(axilClk) then
         axilR <= axilRin after TPD_G;
      end if;
   end process;

   TX_FIFO : entity surf.AxiStreamFifoV2
      generic map (
         -- General Configurations
         TPD_G               => TPD_G,
         INT_PIPE_STAGES_G   => INT_PIPE_STAGES_G,
         PIPE_STAGES_G       => PIPE_STAGES_G,
         SLAVE_READY_EN_G    => true,
         -- FIFO configurations
         SYNTH_MODE_G        => SYNTH_MODE_G,
         MEMORY_TYPE_G       => FIFO_MEMORY_TYPE_G,
         GEN_SYNC_FIFO_G     => GEN_SYNC_FIFO_G,
         FIFO_ADDR_WIDTH_G   => FIFO_ADDR_WIDTH_G,
         -- AXI Stream Port Configurations
         SLAVE_AXI_CONFIG_G  => AXIS_CONFIG_C,
         MASTER_AXI_CONFIG_G => AXI_STREAM_CONFIG_G)
      port map (
         -- Slave Port
         sAxisClk    => axilClk,
         sAxisRst    => axilRst,
         sAxisMaster => axilR.txMaster,
         sAxisSlave  => txSlave,
         -- Master Port
         mAxisClk    => axisClk,
         mAxisRst    => axisRst,
         mAxisMaster => axisMaster,
         mAxisSlave  => axisSlave);

end rtl;
